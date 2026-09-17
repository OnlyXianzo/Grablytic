package com.theonly.grablytic

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteDatabaseLockedException
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

// ---------------------------------------------------------------------------
// Item 6 (dual-engine SQLite races): shared Kotlin-side SQLite discipline.
//
// `app_flutter/grablytic.db` has TWO owners inside one process:
//   * Dart sqflite (canonical owner) — see
//     lib/core/database/download_history_db.dart `_initDb` (lines 184-287):
//     plain `openDatabase`, NO `onConfigure`, NO `PRAGMA journal_mode`, NO
//     busy-timeout. Upstream sqflite keeps WAL disabled by default on
//     Android (it needs either the manifest meta-data
//     `com.tekartik.sqflite.wal_enabled` or an `onConfigure` PRAGMA; neither
//     is present — AndroidManifest.xml has no such meta-data), so the file
//     runs in rollback-journal (DELETE) mode with the platform default
//     busy-timeout of 0: any write/write overlap fails immediately with
//     SQLITE_BUSY instead of waiting.
//   * Kotlin ad-hoc connections (this file + ObservedSourcesPollWorker).
//
// A true single owner would need the sweep/query path moved behind a
// MethodChannel owned by Dart; Dart is frozen for this item, so Kotlin
// implements the feasible subset:
//   1. `grablyticDbGate` serializes every Kotlin-side opener (same process).
//   2. `PRAGMA busy_timeout` on every Kotlin connection lets SQLite itself
//      wait out Dart's short writes (heartbeat single-row updates at
//      download_history_db.dart:340-359, batch seen-ledger commits at
//      :458-479) instead of failing instantly.
//   3. Bounded open/exec retry with backoff for residual BUSY, with LOUD
//      failures (`Log.e` / `SWEEP_DEFERRED`) instead of the old catch-all
//      `Log.w + return 0`, which disguised "database locked" as "clean".
//
// Deliberately NOT done here: `CREATE_IF_NECESSARY` (must never conjure an
// empty file that confuses sqflite version/migration bookkeeping), any
// `PRAGMA journal_mode` / `synchronous` / `wal_checkpoint` (durability and
// checkpointing belong to the Dart owner; forcing WAL or checkpointing from
// a secondary connection risks checkpoint fights while Dart migrates).
// ---------------------------------------------------------------------------

/** Max open+exec attempts per Kotlin-side DB access before giving up. */
internal const val GRABLYTIC_DB_MAX_ATTEMPTS = 3

/** Per-connection SQLite busy-timeout (ms); SQLite waits internally, no thread sleeps. */
internal const val GRABLYTIC_DB_BUSY_TIMEOUT_MS = 2500

/** Sleeps between attempts (size MAX_ATTEMPTS - 1); always done OUTSIDE [grablyticDbGate]. */
internal val GRABLYTIC_DB_RETRY_DELAYS_MS = longArrayOf(150L, 400L)

/** Serializes every Kotlin-side opener of grablytic.db (same process only). */
internal val grablyticDbGate = Any()

/** File handle; null when the Dart owner has never created the DB. */
internal fun grablyticDbFile(context: Context): File? {
    val parent = context.filesDir.parentFile ?: return null
    val dbFile = File(parent, "app_flutter/grablytic.db")
    return if (dbFile.isFile) dbFile else null
}

internal fun openGrablyticDb(dbFile: File, readOnly: Boolean = false): SQLiteDatabase {
    val flags = if (readOnly) SQLiteDatabase.OPEN_READONLY else SQLiteDatabase.OPEN_READWRITE
    val db = SQLiteDatabase.openDatabase(dbFile.absolutePath, null, flags)
    try {
        db.execSQL("PRAGMA busy_timeout=$GRABLYTIC_DB_BUSY_TIMEOUT_MS")
    } catch (e: Exception) {
        try { db.close() } catch (_: Exception) {}
        throw e
    }
    return db
}

/**
 * True for SQLITE_BUSY (5) / SQLITE_LOCKED (6): the Dart owner holds the
 * lock — back off and retry. Anything else is a real error: fail fast.
 */
internal fun isGrablyticDbBusy(e: Exception): Boolean {
    if (e is SQLiteDatabaseLockedException) return true
    val msg = e.message ?: return false
    return msg.contains("SQLITE_BUSY") ||
        msg.contains("SQLITE_LOCKED") ||
        msg.contains("database is locked", ignoreCase = true)
}

internal fun sleepQuietly(ms: Long): Boolean {
    return try {
        Thread.sleep(ms)
        true
    } catch (_: InterruptedException) {
        Thread.currentThread().interrupt()
        false
    }
}

/**
 * Runs [block] on a short-lived, busy-timeout-armed connection, serialized
 * through [grablyticDbGate] and retried on SQLITE_BUSY. Throws the last busy
 * error when attempts are exhausted; rethrows anything else immediately.
 * Callers keep the connection SHORT: never do network I/O inside [block].
 */
internal fun <T> withGrablyticDb(
    dbFile: File,
    readOnly: Boolean = false,
    maxAttempts: Int = GRABLYTIC_DB_MAX_ATTEMPTS,
    block: (SQLiteDatabase) -> T,
): T {
    var lastBusy: Exception? = null
    for (attempt in 1..maxAttempts) {
        try {
            synchronized(grablyticDbGate) {
                openGrablyticDb(dbFile, readOnly).use { db -> return block(db) }
            }
        } catch (e: Exception) {
            if (isGrablyticDbBusy(e) && attempt < maxAttempts) {
                lastBusy = e
                Log.w(
                    "GrablyticDb",
                    "grablytic.db locked by Dart owner (attempt $attempt/$maxAttempts); backing off",
                )
                if (!sleepQuietly(GRABLYTIC_DB_RETRY_DELAYS_MS.getOrElse(attempt - 1) { 400L })) break
                continue
            }
            throw e
        }
    }
    throw lastBusy ?: IllegalStateException("withGrablyticDb exhausted attempts without an error")
}

object DownloadDbSweepHelper {
    private const val TAG = "DownloadDbSweep"

    /**
     * Returned when the sweep could not obtain the DB lock within budget.
     * Callers MUST NOT treat it as clean: the canonical Dart startup sweep
     * (`DownloadHistoryDb.sweepActiveToInterrupted`, driven by
     * `DownloadProvider.restoreInterruptedDownloads` at
     * lib/providers/download_provider.dart:656-657) will redo the work once
     * the Dart owner is up.
     */
    const val SWEEP_DEFERRED = -1

    /**
     * Best-effort Kotlin-side sweep. Single UPDATE statement, hence atomic
     * without an explicit transaction. Callers: [BootReceiver] (background
     * thread via `goAsync`) and `DownloadService.onTimeout`.
     */
    fun sweepActiveToInterrupted(context: Context): Int {
        val dbFile = grablyticDbFile(context) ?: return 0
        return try {
            withGrablyticDb(dbFile) { db ->
                val hasTable = db.rawQuery(
                    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='downloads'", null,
                ).use { it.moveToFirst() }
                if (!hasTable) {
                    Log.i(TAG, "downloads table absent; nothing to sweep")
                    return@withGrablyticDb 0
                }

                val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
                sdf.timeZone = TimeZone.getTimeZone("UTC")
                val nowIso = sdf.format(Date())

                val count = db.compileStatement(
                    "UPDATE downloads SET status = 'interrupted', updatedAt = ? " +
                        "WHERE status IN ('downloading', 'queued', 'pending', 'cancelling')",
                ).use { stmt ->
                    stmt.bindString(1, nowIso)
                    stmt.executeUpdateDelete()
                }
                if (count > 0) {
                    Log.i(TAG, "Swept $count active download(s) to 'interrupted' at $nowIso")
                }
                count
            }
        } catch (e: Exception) {
            if (isGrablyticDbBusy(e)) {
                // Dart sqflite holds the lock (e.g. onTimeout racing a Dart
                // heartbeat/batch). Report loudly; the canonical Dart sweep
                // redoes this work at startup.
                Log.e(
                    TAG,
                    "Sweep DEFERRED after $GRABLYTIC_DB_MAX_ATTEMPTS attempts: " +
                        "Dart owner holds grablytic.db; canonical Dart sweep will redo it",
                    e,
                )
                SWEEP_DEFERRED
            } else {
                Log.e(TAG, "Database sweep failed: ${e.message}", e)
                0
            }
        }
    }
}

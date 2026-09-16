package com.theonly.grablytic

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Handles device boot and package updates for DB-driven download resume.
 *
 * Background safety constraint:
 * A BOOT_COMPLETED receiver must NEVER start ForegroundService (dataSync)
 * directly — targetSdk 35+ throws ForegroundServiceStartNotAllowedException!
 *
 * Instead, this receiver sweeps lingering active/queued download rows in
 * SQLite to 'interrupted' state so they are cleanly re-driven when the app
 * starts or foregrounds.
 */
class BootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "BootReceiver"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) {
            return
        }
        Log.i(TAG, "Handling broadcast: $action")

        try {
            // Locate grablytic.db in Flutter documents directory. Every
            // step is guarded: work profiles / backup-restores can move or
            // drop filesDir, and the DB may predate the downloads table.
            val filesDir = context.filesDir ?: run {
                Log.d(TAG, "No filesDir; skipping boot sweep")
                return
            }
            val parent = filesDir.parentFile ?: run {
                Log.d(TAG, "No parent for filesDir; skipping boot sweep")
                return
            }
            val dbFile = File(File(parent, "app_flutter"), "grablytic.db")
            if (!dbFile.isFile) {
                Log.d(TAG, "No database file found at ${dbFile.absolutePath}")
                return
            }

            val db = SQLiteDatabase.openDatabase(
                dbFile.absolutePath,
                null,
                SQLiteDatabase.OPEN_READWRITE
            )

            db.use { database ->
                // Never assume the schema: older/newer DBs may lack the
                // table or columns (openDatabase does no version check).
                val hasTable = try {
                    database.compileStatement(
                        "SELECT name FROM sqlite_master WHERE type='table' AND name='downloads'"
                    ).use { stmt ->
                        try {
                            stmt.simpleQueryForString() == "downloads"
                        } catch (_: Exception) {
                            false
                        }
                    }
                } catch (_: Exception) {
                    false
                }
                if (!hasTable) {
                    Log.d(TAG, "No downloads table; skipping boot sweep")
                    return
                }
                val columns = try {
                    database.rawQuery("PRAGMA table_info(downloads)", null).use { c ->
                        generateSequence {
                            if (c.moveToNext()) c.getString(1) else null
                        }.toSet()
                    }
                } catch (_: Exception) {
                    emptySet<String>()
                }
                if (!columns.contains("status") || !columns.contains("updatedAt")) {
                    Log.d(TAG, "downloads table lacks sweep columns; skipping")
                    return
                }

                val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
                    timeZone = TimeZone.getTimeZone("UTC")
                }
                val now = sdf.format(Date())

                // Mark in-flight downloads as interrupted. All four
                // non-terminal active states (mirrors Dart
                // sweepActiveToInterrupted): the old two-status sweep left
                // pending/cancelling rows as reboot zombies no bucket or
                // resume query ever matched.
                val values = android.content.ContentValues().apply {
                    put("status", "interrupted")
                    put("updatedAt", now)
                }

                val affected = database.update(
                    "downloads",
                    values,
                    "status IN (?, ?, ?, ?)",
                    arrayOf("downloading", "queued", "pending", "cancelling")
                )
                Log.i(TAG, "Swept $affected active downloads to interrupted on boot")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to sweep downloads on boot: ${e.message}", e)
        }
    }
}

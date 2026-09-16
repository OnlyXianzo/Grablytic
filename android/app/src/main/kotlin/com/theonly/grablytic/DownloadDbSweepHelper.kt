package com.theonly.grablytic

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

object DownloadDbSweepHelper {
    private const val TAG = "DownloadDbSweep"

    fun sweepActiveToInterrupted(context: Context): Int {
        val dbFile = File(context.filesDir.parentFile, "app_flutter/grablytic.db")
        if (!dbFile.exists() || !dbFile.isFile) return 0

        var db: SQLiteDatabase? = null
        return try {
            db = SQLiteDatabase.openDatabase(dbFile.path, null, SQLiteDatabase.OPEN_READWRITE)
            val cursor = db.rawQuery(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='downloads'", null
            )
            val hasTable = cursor.use { it.moveToFirst() }
            if (!hasTable) return 0

            val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
            sdf.timeZone = TimeZone.getTimeZone("UTC")
            val nowIso = sdf.format(Date())

            val count = db.compileStatement(
                "UPDATE downloads SET status = 'interrupted', updatedAt = ? " +
                "WHERE status IN ('downloading', 'queued', 'pending', 'cancelling')"
            ).use { stmt ->
                stmt.bindString(1, nowIso)
                stmt.executeUpdateDelete()
            }
            if (count > 0) {
                Log.i(TAG, "Swept $count active download(s) to 'interrupted' at $nowIso")
            }
            count
        } catch (e: Exception) {
            Log.w(TAG, "Database sweep failed: ${e.message}")
            0
        } finally {
            try { db?.close() } catch (_: Exception) {}
        }
    }
}

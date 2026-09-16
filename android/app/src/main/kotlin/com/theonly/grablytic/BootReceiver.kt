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
            val count = DownloadDbSweepHelper.sweepActiveToInterrupted(context)
            Log.i(TAG, "Swept $count active downloads to interrupted on boot")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to sweep downloads on boot: ${e.message}", e)
        }
    }
}

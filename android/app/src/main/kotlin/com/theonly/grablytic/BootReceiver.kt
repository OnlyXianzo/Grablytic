package com.theonly.grablytic

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

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
 *
 * Item 6 (dual-engine SQLite races): this receiver no longer touches
 * `grablytic.db` directly. All SQLite access funnels through
 * [DownloadDbSweepHelper.sweepActiveToInterrupted], which serializes
 * Kotlin-side openers, arms busy-timeout + bounded retry against the Dart
 * sqflite owner, and reports a lock-out loudly via
 * [DownloadDbSweepHelper.SWEEP_DEFERRED] instead of disguising it as clean.
 * A deferred boot sweep is safe: the canonical Dart startup sweep
 * (`DownloadHistoryDb.sweepActiveToInterrupted`, driven by
 * `DownloadProvider.restoreInterruptedDownloads`) redoes the work when the
 * app process starts.
 *
 * The sweep runs on a background thread via `goAsync()`: the helper waits
 * out Dart's lock with busy-timeout + retries, which must never block
 * `onReceive` on the main thread.
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

        val pending = goAsync()
        Thread({
            try {
                when (val count = DownloadDbSweepHelper.sweepActiveToInterrupted(context)) {
                    DownloadDbSweepHelper.SWEEP_DEFERRED ->
                        Log.w(
                            TAG,
                            "Boot sweep deferred (grablytic.db locked); " +
                                "canonical Dart startup sweep will redo it",
                        )
                    else -> Log.i(TAG, "Swept $count active downloads to interrupted on $action")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to sweep downloads on boot: ${e.message}", e)
            } finally {
                pending.finish()
            }
        }, "GrablyticBootSweep").start()
    }
}

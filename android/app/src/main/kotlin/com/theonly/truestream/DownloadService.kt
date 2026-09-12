package com.theonly.truestream

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Keeps the process alive while downloads run (screen locked, activity dead).
 *
 * Verified design notes (see team-review research, Sept 2026):
 * - Type is `dataSync` (downloads), NOT mediaPlayback/specialUse — using the
 *   wrong type risks Play rejection / InvalidForegroundServiceTypeException.
 * - No new runtime permissions: FOREGROUND_SERVICE + DATA_SYNC are
 *   install-time. FGS notifications are exempt from POST_NOTIFICATIONS.
 * - START_NOT_STICKY + explicit start/stop: the starter (MainActivity)
 *   owns lifetime via an active-download counter, so no zombie notification.
 * - onTimeout() stops the service: dataSync FGS is limited (~6h/24h in
 *   background on recent Android); exceeding it without stopSelf() crashes.
 * - This covers *process survival*. Process *death* (LMK, reboot, 6h cap)
 *   still needs DB-driven resume (WorkManager/UIDT) — tracked follow-up,
 *   not claimed here. BOOT_COMPLETED must never start this service
 *   directly (ForegroundServiceStartNotAllowedException on targetSdk 35+).
 *
 * NOTE: needs Android SDK compile + on-device verification (not available
 * in this workspace); logic mirrors ytdlnis DownloadWorker + ExoPlayer
 * DownloadService patterns.
 */
class DownloadService : Service() {

    private val active = linkedMapOf<String, String>() // downloadId -> title
    private var lastPercent = -1
    private var lastStage: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val id = intent.getStringExtra(EXTRA_ID) ?: return START_NOT_STICKY
                active[id] = intent.getStringExtra(EXTRA_TITLE) ?: id
                promote()
            }
            ACTION_UPDATE -> {
                val id = intent.getStringExtra(EXTRA_ID) ?: return START_NOT_STICKY
                if (active.containsKey(id)) {
                    lastPercent = intent.getIntExtra(EXTRA_PERCENT, lastPercent)
                    val stage = intent.getStringExtra(EXTRA_STAGE)
                    if (stage != null) {
                        lastStage = stage
                    } else if (lastPercent in 0..99) {
                        lastStage = null
                    }
                    promote()
                }
            }
            ACTION_DONE, ACTION_CANCEL -> {
                active.remove(intent?.getStringExtra(EXTRA_ID))
                if (active.isEmpty()) {
                    lastStage = null
                    stopSelf()
                } else {
                    promote()
                }
            }
            ACTION_STOP -> stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int) {
        // dataSync background quota exhausted — stop now or the OS crashes us.
        // Interrupted items stay 'downloading' in the Flutter layer and are
        // re-driven on next launch (DB resume is the follow-up).
        stopSelf()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Don't linger when the user swipes the app away with nothing active.
        if (active.isEmpty()) stopSelf()
    }

    private fun promote() {
        val notif = buildNotification()
        try {
            ServiceCompat.startForeground(
                this,
                NOTIF_ID,
                notif,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } catch (_: Exception) {
            // Couldn't foreground (background-start restriction etc.) —
            // never crash the app over the keep-alive mechanism.
            if (active.isEmpty()) stopSelf()
        }
    }

    private fun buildNotification(): Notification {
        val openApp = PendingIntent.getActivity(
            this, 0, packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val cancelAll = PendingIntent.getService(
            this, 1, Intent(this, DownloadService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val title = if (active.size == 1) active.values.first() else "${active.size} downloads"
        val contentText = when {
            lastStage != null -> lastStage
            lastPercent in 0..99 -> "$lastPercent%"
            else -> "Downloading…"
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(contentText)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(openApp)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(100, lastPercent.coerceIn(0, 100), lastPercent !in 0..100)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", cancelAll)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(NotificationManager::class.java) ?: return
        if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
            mgr.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Downloads",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply { description = "Shows active download progress" },
            )
        }
    }

    companion object {
        const val ACTION_START = "com.theonly.truestream.download.START"
        const val ACTION_UPDATE = "com.theonly.truestream.download.UPDATE"
        const val ACTION_DONE = "com.theonly.truestream.download.DONE"
        const val ACTION_CANCEL = "com.theonly.truestream.download.CANCEL"
        const val ACTION_STOP = "com.theonly.truestream.download.STOP"
        const val EXTRA_ID = "download_id"
        const val EXTRA_TITLE = "title"
        const val EXTRA_PERCENT = "percent"
        const val EXTRA_STAGE = "stage"
        private const val CHANNEL_ID = "truestream_downloads"
        private const val NOTIF_ID = 1001

        fun start(ctx: Context, downloadId: String, title: String) {
            val intent = Intent(ctx, DownloadService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_ID, downloadId)
                putExtra(EXTRA_TITLE, title)
            }
            start(ctx, intent)
        }

        fun update(ctx: Context, downloadId: String, percent: Int) {
            val intent = Intent(ctx, DownloadService::class.java).apply {
                action = ACTION_UPDATE
                putExtra(EXTRA_ID, downloadId)
                putExtra(EXTRA_PERCENT, percent)
            }
            start(ctx, intent)
        }

        fun updateStage(ctx: Context, downloadId: String, stageLabel: String) {
            val intent = Intent(ctx, DownloadService::class.java).apply {
                action = ACTION_UPDATE
                putExtra(EXTRA_ID, downloadId)
                putExtra(EXTRA_STAGE, stageLabel)
                putExtra(EXTRA_PERCENT, 99)
            }
            start(ctx, intent)
        }

        fun done(ctx: Context, downloadId: String, cancelled: Boolean = false) {
            val intent = Intent(ctx, DownloadService::class.java).apply {
                action = if (cancelled) ACTION_CANCEL else ACTION_DONE
                putExtra(EXTRA_ID, downloadId)
            }
            start(ctx, intent)
        }

        private fun start(ctx: Context, intent: Intent) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ctx.startForegroundService(intent)
                } else {
                    ctx.startService(intent)
                }
            } catch (_: Exception) {
                // Background-start restriction etc. — downloads continue
                // without keep-alive rather than crashing.
            }
        }
    }
}

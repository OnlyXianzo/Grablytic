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
 * - Runtime permissions: POST_NOTIFICATIONS is requested on API 33+ for
 *   completion/failure alerts (the FGS progress notification itself is
 *   exempt). Battery exemption is user-initiated from Settings.
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

    private data class Prog(
        var percent: Int = -1,
        var stage: String? = null,
        var speedBps: Long = 0,
        var downloadedBytes: Long = 0,
        var totalBytes: Long = 0,
    )

    private val active = linkedMapOf<String, String>() // downloadId -> title
    private val prog = linkedMapOf<String, Prog>() // downloadId -> progress
    private var lastShownId: String? = null
    private var lastPromoteMs: Long = 0

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
                    val p = prog.getOrPut(id) { Prog() }
                    if (intent.hasExtra(EXTRA_PERCENT)) {
                        p.percent = intent.getIntExtra(EXTRA_PERCENT, p.percent)
                    }
                    val stage = intent.getStringExtra(EXTRA_STAGE)
                    if (stage != null) {
                        p.stage = stage
                    } else if (p.percent in 0..99) {
                        p.stage = null
                    }
                    if (intent.hasExtra(EXTRA_SPEED)) {
                        p.speedBps = intent.getLongExtra(EXTRA_SPEED, p.speedBps)
                    }
                    if (intent.hasExtra(EXTRA_DOWNLOADED)) {
                        p.downloadedBytes = intent.getLongExtra(EXTRA_DOWNLOADED, p.downloadedBytes)
                    }
                    if (intent.hasExtra(EXTRA_TOTAL)) {
                        p.totalBytes = intent.getLongExtra(EXTRA_TOTAL, p.totalBytes)
                    }
                    lastShownId = id
                    // Coalesce rebuilds: engine `downloading` events arrive
                    // far faster than the OS can usefully re-render.
                    // Always refresh on stage change or near-completion.
                    val now = android.os.SystemClock.elapsedRealtime()
                    val force = stage != null || p.percent >= 99 || p.percent < 0
                    if (force || now - lastPromoteMs >= 500) {
                        lastPromoteMs = now
                        promote()
                    }
                }
            }
            ACTION_DONE, ACTION_CANCEL -> {
                active.remove(intent?.getStringExtra(EXTRA_ID))
                prog.remove(intent?.getStringExtra(EXTRA_ID))
                if (active.isEmpty()) {
                    lastShownId = null
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
        // Show the most recently updated download; title collapses under
        // concurrency (unchanged behavior).
        val shownId = lastShownId?.takeIf { active.containsKey(it) }
            ?: active.keys.lastOrNull()
        val title = if (active.size == 1) active.values.first() else "${active.size} downloads"
        val p = shownId?.let { prog[it] }
        val pct = p?.percent ?: -1
        val contentText = when {
            p?.stage != null -> p.stage
            pct in 0..99 -> buildProgressLine(pct, p)
            else -> "Downloading…"
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(contentText)
            .setStyle(NotificationCompat.BigTextStyle().bigText(contentText))
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(openApp)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(100, pct.coerceIn(0, 100), pct !in 0..100)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", cancelAll)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .build()
    }

    private fun buildProgressLine(pct: Int, p: Prog?): String {
        if (p == null) return "$pct%"
        val parts = ArrayList<String>(3)
        parts.add("$pct%")
        if (p.speedBps > 0) parts.add(formatSpeed(p.speedBps))
        if (p.totalBytes > 0) {
            parts.add("${formatBytes(p.downloadedBytes)} / ${formatBytes(p.totalBytes)}")
        } else if (p.downloadedBytes > 0) {
            parts.add(formatBytes(p.downloadedBytes))
        }
        return parts.joinToString(" · ")
    }

    private fun formatBytes(bytes: Long): String {
        if (bytes < 1024) return "$bytes B"
        val kb = bytes / 1024.0
        if (kb < 1024) return String.format(java.util.Locale.US, "%.1f KB", kb)
        val mb = kb / 1024.0
        if (mb < 1024) return String.format(java.util.Locale.US, "%.1f MB", mb)
        return String.format(java.util.Locale.US, "%.2f GB", mb / 1024.0)
    }

    private fun formatSpeed(bps: Long): String = "${formatBytes(bps)}/s"

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
        const val EXTRA_SPEED = "speed_bps"
        const val EXTRA_DOWNLOADED = "downloaded_bytes"
        const val EXTRA_TOTAL = "total_bytes"
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

        fun update(
            ctx: Context,
            downloadId: String,
            percent: Int,
            speedBps: Long = 0,
            downloadedBytes: Long = 0,
            totalBytes: Long = 0,
        ) {
            val intent = Intent(ctx, DownloadService::class.java).apply {
                action = ACTION_UPDATE
                putExtra(EXTRA_ID, downloadId)
                putExtra(EXTRA_PERCENT, percent)
                putExtra(EXTRA_SPEED, speedBps)
                putExtra(EXTRA_DOWNLOADED, downloadedBytes)
                putExtra(EXTRA_TOTAL, totalBytes)
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

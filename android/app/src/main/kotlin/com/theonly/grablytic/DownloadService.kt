package com.theonly.grablytic

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
import androidx.core.app.NotificationManagerCompat
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
 *
 * T2-1 power locks (verified approach, Sept 2026 — official WakeLock/WifiLock
 * refs + NewPipe queue-active scope + vitals/Doze failure-modes research):
 * - One non-counted PARTIAL_WAKE_LOCK + one non-counted WifiLock, held exactly
 *   while `active` is non-empty (queue-active window), released on every idle
 *   transition, STOP, quota timeout, and onDestroy. Stable tags (no per-ID
 *   tags) for clean vitals attribution.
 * - WifiLock mode branches on API 34: WIFI_MODE_FULL_HIGH_PERF below 34,
 *   WIFI_MODE_FULL_LOW_LATENCY on 34+ (HIGH_PERF is auto-remapped there and
 *   FULL has been non-functional since API 29 — requesting either blindly is
 *   theater). Only WAKE_LOCK permission is needed for both locks.
 * - WakeLock uses acquire(6h) as a leak backstop, renewed on transitions so a
 *   legitimate multi-hour hold is never cut mid-download (6h matches the
 *   dataSync quota: past it the service is demoted anyway).
 * - Honest limits (documented, not fixed here): deep Doze suspends network and
 *   ignores wake locks regardless of these holders — the battery-exemption
 *   Settings toggle remains the Doze lever; UIDT migration is the designated
 *   long-term path and a separate ticket. Verify on-device with
 *   `adb shell dumpsys batterystats` (Grablytic:Download tag history).
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
    private val alertPrefs = linkedMapOf<String, Boolean>() // downloadId -> show terminal alert
    private var lastShownId: String? = null
    private var lastPromoteMs: Long = 0

    // T2-1: single-owner power holders. Non-counted + isHeld() guards so N
    // concurrent downloads share one logical "held while active non-empty"
    // state — never per-download acquire/release pairing (under-lock crash).
    private var wakeLock: android.os.PowerManager.WakeLock? = null
    private var wifiLock: android.net.wifi.WifiManager.WifiLock? = null
    private var wakeAcquiredAtMs: Long = 0

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
                alertPrefs[id] = intent.getBooleanExtra(EXTRA_SHOW_ALERT, true)
                promote()
                updateLocks()
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
            ACTION_FINISHED -> {
                val id = intent.getStringExtra(EXTRA_ID)
                val title = id?.let { active[it] } ?: id ?: "Download"
                val showAlert = id?.let { alertPrefs[it] } ?: true
                active.remove(id)
                prog.remove(id)
                alertPrefs.remove(id)
                if (showAlert && id != null) {
                    postTerminalAlert(id, title, succeeded = true, detail = null)
                }
                updateLocks()
                if (active.isEmpty()) {
                    lastShownId = null
                    stopSelf()
                } else {
                    promote()
                }
            }
            ACTION_FAILED -> {
                val id = intent.getStringExtra(EXTRA_ID)
                val title = id?.let { active[it] } ?: id ?: "Download"
                val detail = intent.getStringExtra(EXTRA_DETAIL)
                val showAlert = id?.let { alertPrefs[it] } ?: true
                active.remove(id)
                prog.remove(id)
                alertPrefs.remove(id)
                if (showAlert && id != null) {
                    postTerminalAlert(id, title, succeeded = false, detail = detail)
                }
                updateLocks()
                if (active.isEmpty()) {
                    lastShownId = null
                    stopSelf()
                } else {
                    promote()
                }
            }
            ACTION_DONE, ACTION_CANCEL -> {
                active.remove(intent?.getStringExtra(EXTRA_ID))
                prog.remove(intent?.getStringExtra(EXTRA_ID))
                alertPrefs.remove(intent?.getStringExtra(EXTRA_ID))
                updateLocks()
                if (active.isEmpty()) {
                    lastShownId = null
                    stopSelf()
                } else {
                    promote()
                }
            }
            ACTION_STOP -> {
                active.clear()
                prog.clear()
                alertPrefs.clear()
                releaseLocks()
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int) {
        // dataSync background quota exhausted — stop now or the OS crashes us.
        // Interrupted items stay 'downloading' in the Flutter layer and are
        // re-driven on next launch (DB resume is the follow-up).
        releaseLocks()
        stopSelf()
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Don't linger when the user swipes the app away with nothing active.
        if (active.isEmpty()) stopSelf()
    }

    /**
     * Single owner for both power holders: held if and only if `active` is
     * non-empty. Call after every membership change; release paths also run
     * from STOP, onTimeout, and onDestroy so no stop path leaks (§5: six
     * stopSelf sites + death; death itself is binder-cleaned by the OS).
     */
    private fun updateLocks() {
        if (active.isEmpty()) {
            releaseLocks()
            return
        }
        ensureLocks()
        val now = android.os.SystemClock.elapsedRealtime()
        try {
            val wl = wakeLock
            if (wl != null && !wl.isHeld) {
                wl.acquire(WAKE_TIMEOUT_MS)
                wakeAcquiredAtMs = now
            } else if (wl != null && wl.isHeld && now - wakeAcquiredAtMs >= WAKE_RENEW_MS) {
                // Renew the backstop without dropping the hold, so a
                // legitimate multi-hour download is never cut mid-transfer.
                try { wl.release() } catch (_: Exception) {}
                wl.acquire(WAKE_TIMEOUT_MS)
                wakeAcquiredAtMs = now
            }
        } catch (_: Exception) { /* keep-alive must never crash downloads */ }
        try {
            val fl = wifiLock
            if (fl != null && !fl.isHeld) fl.acquire()
        } catch (_: Exception) { /* keep-alive must never crash downloads */ }
    }

    private fun ensureLocks() {
        if (wakeLock == null) {
            try {
                val pm = getSystemService(android.os.PowerManager::class.java) ?: return
                wakeLock = pm.newWakeLock(android.os.PowerManager.PARTIAL_WAKE_LOCK, WAKE_TAG)
                wakeLock?.setReferenceCounted(false)
            } catch (_: Exception) { wakeLock = null }
        }
        if (wifiLock == null) {
            try {
                val wm = applicationContext.getSystemService(android.content.Context.WIFI_SERVICE)
                    as? android.net.wifi.WifiManager ?: return
                // FULL is non-functional since API 29; HIGH_PERF is remapped
                // on API 34+, so branch explicitly instead of relying on it.
                val mode = if (Build.VERSION.SDK_INT >= 34)
                    android.net.wifi.WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                else
                    android.net.wifi.WifiManager.WIFI_MODE_FULL_HIGH_PERF
                wifiLock = wm.createWifiLock(mode, WIFI_TAG)
                wifiLock?.setReferenceCounted(false)
            } catch (_: Exception) { wifiLock = null }
        }
    }

    private fun releaseLocks() {
        try {
            val wl = wakeLock
            if (wl != null && wl.isHeld) wl.release()
        } catch (_: Exception) {}
        try {
            val fl = wifiLock
            if (fl != null && fl.isHeld) fl.release()
        } catch (_: Exception) {}
        wakeAcquiredAtMs = 0
    }

    private fun promote() {
        try {
            val notif = buildNotification()
            try {
                ServiceCompat.startForeground(
                    this,
                    NOTIF_ID,
                    notif,
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
            } catch (e: Exception) {
                // Couldn't foreground (background-start restriction etc.) —
                // never crash the app over the keep-alive mechanism.
                android.util.Log.w("DownloadService", "startForeground failed: ${e.message}")
                if (active.isEmpty()) stopSelf()
            }
        } catch (e: Exception) {
            // buildNotification itself must never crash onStartCommand
            // (e.g. null launch intent). Log loudly — a logging/notify path
            // must never break downloads, but the FIRST failure warns.
            android.util.Log.w("DownloadService", "buildNotification failed: ${e.message}")
            if (active.isEmpty()) stopSelf()
        }
    }

    private fun openAppIntent(): PendingIntent {
        val launch = try {
            packageManager.getLaunchIntentForPackage(packageName)
        } catch (_: Exception) {
            null
        }
        val target = launch ?: Intent(this, MainActivity::class.java)
        return PendingIntent.getActivity(
            this, 0, target,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun notificationsEnabled(): Boolean {
        return try {
            NotificationManagerCompat.from(this).areNotificationsEnabled()
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Terminal completion/failure alert (separate HIGH-importance channel +
     * per-download ID so concurrent finishes don't overwrite each other).
     * The FGS progress row (NOTIF_ID) is updated/removed separately; this
     * alert is an ordinary notification so it REQUIRES POST_NOTIFICATIONS
     * on API 33+ — checked here, silently skipped when denied (in-app list
     * UI remains the source of truth).
     */
    private fun postTerminalAlert(
        downloadId: String,
        title: String,
        succeeded: Boolean,
        detail: String?,
    ) {
        if (!notificationsEnabled()) return
        try {
            val channel = if (succeeded) CHANNEL_COMPLETE else CHANNEL_ERROR
            val contentTitle = if (succeeded) "Download complete" else "Download failed"
            val contentText = if (succeeded) title else (detail?.take(200) ?: title)
            val notif = NotificationCompat.Builder(this, channel)
                .setContentTitle(contentTitle)
                .setContentText(contentText)
                .setStyle(NotificationCompat.BigTextStyle().bigText(contentText))
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentIntent(openAppIntent())
                .setAutoCancel(true)
                .setOnlyAlertOnce(false)
                .setCategory(NotificationCompat.CATEGORY_STATUS)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .build()
            val mgr = getSystemService(NotificationManager::class.java) ?: return
            mgr.notify(alertNotifId(downloadId), notif)
        } catch (e: Exception) {
            android.util.Log.w("DownloadService", "terminal alert failed: ${e.message}")
        }
    }

    private fun buildNotification(): Notification {
        val openApp = openAppIntent()
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
        if (mgr.getNotificationChannel(CHANNEL_COMPLETE) == null) {
            mgr.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_COMPLETE,
                    "Download complete",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply { description = "Alerts when a download finishes" },
            )
        }
        if (mgr.getNotificationChannel(CHANNEL_ERROR) == null) {
            mgr.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ERROR,
                    "Download failed",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply { description = "Alerts when a download fails" },
            )
        }
    }

    companion object {
        private const val WAKE_TAG = "Grablytic:Download"
        private const val WIFI_TAG = "Grablytic:DownloadWifi"
        // Backstop: past the dataSync quota the service is demoted anyway.
        private const val WAKE_TIMEOUT_MS = 6L * 3600L * 1000L
        // Renew before expiry so a legitimate long hold is never cut.
        private const val WAKE_RENEW_MS = 5L * 3600L * 1000L
        const val ACTION_START = "com.theonly.grablytic.download.START"
        const val ACTION_UPDATE = "com.theonly.grablytic.download.UPDATE"
        const val ACTION_DONE = "com.theonly.grablytic.download.DONE"
        const val ACTION_CANCEL = "com.theonly.grablytic.download.CANCEL"
        const val ACTION_FINISHED = "com.theonly.grablytic.download.FINISHED"
        const val ACTION_FAILED = "com.theonly.grablytic.download.FAILED"
        const val ACTION_STOP = "com.theonly.grablytic.download.STOP"
        const val EXTRA_ID = "download_id"
        const val EXTRA_TITLE = "title"
        const val EXTRA_SHOW_ALERT = "show_alert"
        const val EXTRA_DETAIL = "detail"
        const val EXTRA_PERCENT = "percent"
        const val EXTRA_STAGE = "stage"
        const val EXTRA_SPEED = "speed_bps"
        const val EXTRA_DOWNLOADED = "downloaded_bytes"
        const val EXTRA_TOTAL = "total_bytes"
        private const val CHANNEL_ID = "grablytic_downloads"
        private const val CHANNEL_COMPLETE = "grablytic_complete"
        private const val CHANNEL_ERROR = "grablytic_error"
        private const val NOTIF_ID = 1001

        /** Stable per-download alert ID that never collides with NOTIF_ID. */
        fun alertNotifId(downloadId: String): Int {
            val h = downloadId.hashCode() and 0x00FFFFFF
            return 2000 + (h % 200000)
        }

        fun start(ctx: Context, downloadId: String, title: String, showAlert: Boolean = true) {
            val intent = Intent(ctx, DownloadService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_ID, downloadId)
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_SHOW_ALERT, showAlert)
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

        fun finished(ctx: Context, downloadId: String) {
            val intent = Intent(ctx, DownloadService::class.java).apply {
                action = ACTION_FINISHED
                putExtra(EXTRA_ID, downloadId)
            }
            start(ctx, intent)
        }

        fun failed(ctx: Context, downloadId: String, detail: String? = null) {
            val intent = Intent(ctx, DownloadService::class.java).apply {
                action = ACTION_FAILED
                putExtra(EXTRA_ID, downloadId)
                if (detail != null) putExtra(EXTRA_DETAIL, detail.take(500))
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
            } catch (e: Exception) {
                // Background-start restriction etc. — downloads continue
                // without keep-alive rather than crashing. Logged so
                // "download runs with no notification" is diagnosable.
                android.util.Log.w("DownloadService", "service start failed: ${e.message}")
            }
        }
    }
}

package com.theonly.grablytic

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import android.util.Xml
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.xmlpull.v1.XmlPullParser
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone

data class SourceEntry(val id: String, val url: String, val title: String)

/**
 * Background periodic worker for observed sources polling.
 *
 * System constraints:
 * - Uses inexact PeriodicWorkRequest via WorkManager (JobScheduler-backed, Doze-aware).
 * - Never touches exact alarms (avoids SCHEDULE_EXACT_ALARM Play rejection on API 33+).
 * - Two-tier poll: YouTube Atom RSS first (lightweight, bytes, no Python startup),
 *   falls back to Chaquopy extract_flat only when necessary.
 * - Records new videos into SQLite seen_source_videos ledger and inserts pending
 *   rows into downloads table.
 */
class ObservedSourcesPollWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    companion object {
        const val TAG = "ObservedSourcesWorker"
        const val WORK_NAME = "observed-sources-poll"
        private const val NOTIF_CHANNEL_COMPLETE = "grablytic_downloads_complete"

        fun schedule(
            context: Context,
            enabled: Boolean,
            intervalMinutes: Long = 60L,
            wifiOnly: Boolean = true,
            requiresCharging: Boolean = false,
        ) {
            val workManager = androidx.work.WorkManager.getInstance(context)
            if (!enabled) {
                workManager.cancelUniqueWork(WORK_NAME)
                Log.i(TAG, "Cancelled unique work: $WORK_NAME")
                return
            }

            val constraints = androidx.work.Constraints.Builder()
                .setRequiredNetworkType(
                    if (wifiOnly) androidx.work.NetworkType.UNMETERED
                    else androidx.work.NetworkType.CONNECTED
                )
                .setRequiresBatteryNotLow(true)
                .setRequiresStorageNotLow(true)
                .setRequiresCharging(requiresCharging)
                .build()

            val request = androidx.work.PeriodicWorkRequestBuilder<ObservedSourcesPollWorker>(
                intervalMinutes.coerceAtLeast(15L), java.util.concurrent.TimeUnit.MINUTES,
                15L, java.util.concurrent.TimeUnit.MINUTES,
            )
                .setConstraints(constraints)
                .setBackoffCriteria(
                    androidx.work.BackoffPolicy.LINEAR,
                    15L,
                    java.util.concurrent.TimeUnit.MINUTES,
                )
                .build()

            workManager.enqueueUniquePeriodicWork(
                WORK_NAME,
                androidx.work.ExistingPeriodicWorkPolicy.UPDATE,
                request,
            )
            Log.i(TAG, "Enqueued periodic work $WORK_NAME: interval=${intervalMinutes}m, wifiOnly=$wifiOnly, charging=$requiresCharging")
        }
    }

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        try {
            Log.i(TAG, "Starting observed sources background check...")
            val prefs = applicationContext.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

            val scheduleEnabled = prefs.getBoolean("flutter.scheduleEnabled", false)
            val scheduleTime = prefs.getString("flutter.scheduleTime", "22:00") ?: "22:00"
            val scheduleDaysRaw = prefs.getString("flutter.scheduleDays", null)
            val observedSourcesJson = prefs.getString("flutter.observedSources", null)

            if (observedSourcesJson.isNullOrEmpty()) {
                Log.i(TAG, "No observed sources configured, skipping")
                return@withContext Result.success()
            }

            // Window check
            if (scheduleEnabled && !isWithinScheduleWindow(scheduleTime, scheduleDaysRaw)) {
                Log.i(TAG, "Current time outside scheduled window, skipping poll")
                return@withContext Result.success()
            }

            val sourcesArray = try {
                JSONArray(observedSourcesJson)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to parse observedSources JSON: ${e.message}")
                return@withContext Result.success()
            }

            // Locate grablytic.db
            val filesDir = applicationContext.filesDir
            val appFlutterDir = File(filesDir.parentFile, "app_flutter")
            val dbFile = File(appFlutterDir, "grablytic.db")
            if (!dbFile.exists()) {
                Log.w(TAG, "Database grablytic.db not found, skipping poll")
                return@withContext Result.success()
            }

            val db = SQLiteDatabase.openDatabase(dbFile.absolutePath, null, SQLiteDatabase.OPEN_READWRITE)
            var totalNewFound = 0

            db.use { database ->
                // Ensure seen_source_videos table exists in case worker runs before Flutter upgraded
                database.execSQL("""
                    CREATE TABLE IF NOT EXISTS seen_source_videos (
                      source_url TEXT NOT NULL,
                      video_id TEXT NOT NULL,
                      seen_at TEXT NOT NULL,
                      PRIMARY KEY (source_url, video_id)
                    )
                """.trimIndent())
                database.execSQL("CREATE INDEX IF NOT EXISTS idx_seen_source_url ON seen_source_videos(source_url)")

                for (i in 0 until sourcesArray.length()) {
                    if (isStopped) {
                        Log.i(TAG, "Worker stopped by OS constraint or cancellation")
                        break
                    }
                    val sourceObj = sourcesArray.optJSONObject(i) ?: continue
                    val isSourceEnabled = sourceObj.optBoolean("enabled", true)
                    if (!isSourceEnabled) continue

                    val sourceUrl = sourceObj.optString("url", "").trim()
                    val sourceName = sourceObj.optString("name", "Channel")
                    val sourceQuality = sourceObj.optString("quality", "best")
                    if (sourceUrl.isEmpty()) continue

                    val newEntries = checkSource(sourceUrl, database)
                    if (newEntries.isNotEmpty()) {
                        Log.i(TAG, "Found ${newEntries.size} new videos for source: $sourceName ($sourceUrl)")
                        totalNewFound += newEntries.size
                        recordAndQueueEntries(database, sourceUrl, sourceQuality, newEntries)
                    }
                }
            }

            if (totalNewFound > 0) {
                postNotification(totalNewFound)
            }

            Result.success()
        } catch (e: Exception) {
            Log.e(TAG, "Error in observed sources worker: ${e.message}", e)
            Result.retry()
        }
    }

    private fun isWithinScheduleWindow(scheduleTime: String, scheduleDaysRaw: String?): Boolean {
        val cal = Calendar.getInstance()
        val dayOfWeek = cal.get(Calendar.DAY_OF_WEEK)
        val isoWeekday = if (dayOfWeek == Calendar.SUNDAY) 7 else dayOfWeek - 1

        val days = mutableSetOf<Int>()
        if (scheduleDaysRaw != null) {
            try {
                if (scheduleDaysRaw.startsWith("[")) {
                    val arr = JSONArray(scheduleDaysRaw)
                    for (i in 0 until arr.length()) {
                        val d = arr.optString(i).toIntOrNull()
                        if (d != null) days.add(d)
                    }
                } else {
                    scheduleDaysRaw.split(",").forEach { s ->
                        s.trim().toIntOrNull()?.let { days.add(it) }
                    }
                }
            } catch (_: Exception) {}
        }
        if (days.isEmpty()) {
            days.addAll(listOf(1, 2, 3, 4, 5))
        }

        if (!days.contains(isoWeekday)) return false

        val parts = scheduleTime.split(":")
        if (parts.size != 2) return true
        val h = parts[0].toIntOrNull() ?: return true
        val m = parts[1].toIntOrNull() ?: return true
        if (h !in 0..23 || m !in 0..59) return true

        val startMinutes = h * 60 + m
        val currentMinutes = cal.get(Calendar.HOUR_OF_DAY) * 60 + cal.get(Calendar.MINUTE)
        return currentMinutes >= startMinutes
    }

    private fun checkSource(sourceUrl: String, db: SQLiteDatabase): List<SourceEntry> {
        val seenIds = mutableSetOf<String>()
        val cursor = db.rawQuery(
            "SELECT video_id FROM seen_source_videos WHERE source_url = ?",
            arrayOf(sourceUrl),
        )
        cursor.use { c ->
            val idx = c.getColumnIndex("video_id")
            while (c.moveToNext()) {
                seenIds.add(c.getString(idx))
            }
        }

        // Tier 1: Try YouTube channel RSS if applicable
        val rssEntries = tryFetchYouTubeRss(sourceUrl)
        if (rssEntries != null && rssEntries.isNotEmpty()) {
            return rssEntries.filter { it.id !in seenIds }
        }

        // Tier 2: Fallback to Chaquopy extract_flat
        return tryChaquopyFlatExtract(sourceUrl, seenIds)
    }

    private fun tryFetchYouTubeRss(url: String): List<SourceEntry>? {
        val channelIdMatch = "channel/(UC[a-zA-Z0-9_-]{22})".toRegex().find(url)
            ?: "channel_id=(UC[a-zA-Z0-9_-]{22})".toRegex().find(url)

        val feedUrl = when {
            channelIdMatch != null -> "https://www.youtube.com/feeds/videos.xml?channel_id=${channelIdMatch.groupValues[1]}"
            url.contains("/feeds/videos.xml") -> url
            else -> null
        } ?: return null

        return try {
            val conn = URL(feedUrl).openConnection() as HttpURLConnection
            conn.connectTimeout = 10000
            conn.readTimeout = 10000
            conn.requestMethod = "GET"
            conn.setRequestProperty("User-Agent", "Mozilla/5.0 (Android; Grablytic)")
            if (conn.responseCode != 200) {
                return null
            }
            conn.inputStream.use { stream ->
                parseAtomFeed(stream)
            }
        } catch (e: Exception) {
            Log.w(TAG, "RSS fetch failed for $feedUrl: ${e.message}")
            null
        }
    }

    private fun parseAtomFeed(stream: InputStream): List<SourceEntry> {
        val entries = mutableListOf<SourceEntry>()
        val parser = Xml.newPullParser()
        parser.setInput(stream, "UTF-8")

        var eventType = parser.eventType
        var inEntry = false
        var currentId: String? = null
        var currentTitle: String? = null
        var currentUrl: String? = null

        while (eventType != XmlPullParser.END_DOCUMENT) {
            val tagName = parser.name
            when (eventType) {
                XmlPullParser.START_TAG -> {
                    if (tagName.equals("entry", ignoreCase = true)) {
                        inEntry = true
                        currentId = null
                        currentTitle = null
                        currentUrl = null
                    } else if (inEntry) {
                        when {
                            tagName.equals("videoId", ignoreCase = true) -> {
                                currentId = parser.nextText().trim()
                            }
                            tagName.equals("title", ignoreCase = true) && currentTitle == null -> {
                                currentTitle = parser.nextText().trim()
                            }
                            tagName.equals("link", ignoreCase = true) && currentUrl == null -> {
                                val href = parser.getAttributeValue(null, "href")
                                if (href != null && href.startsWith("http")) {
                                    currentUrl = href
                                }
                            }
                            tagName.equals("id", ignoreCase = true) && currentId == null -> {
                                val idText = parser.nextText().trim()
                                val last = idText.substringAfterLast(":")
                                if (last.length == 11) {
                                    currentId = last
                                }
                            }
                        }
                    }
                }
                XmlPullParser.END_TAG -> {
                    if (tagName.equals("entry", ignoreCase = true)) {
                        if (currentId != null && currentId.length == 11) {
                            val finalUrl = currentUrl ?: "https://www.youtube.com/watch?v=$currentId"
                            entries.add(SourceEntry(currentId, finalUrl, currentTitle ?: currentId))
                        }
                        inEntry = false
                    }
                }
            }
            eventType = parser.next()
        }
        return entries
    }

    private fun tryChaquopyFlatExtract(sourceUrl: String, seenIds: Set<String>): List<SourceEntry> {
        return try {
            if (!Python.isStarted()) {
                Python.start(AndroidPlatform(applicationContext))
            }
            val py = Python.getInstance()
            val engine = py.getModule("grablytic_engine")
            val helper = py.getModule("grablytic_engine.scheduler_check")

            val playlistResult = engine.callAttr("get_playlist_info", sourceUrl, "{}")
            val entriesPy = playlistResult?.callAttr("get", "entries") ?: return emptyList()

            val idsPy = helper.callAttr("flat_entries_to_ids", entriesPy).asList()
            val entries = mutableListOf<SourceEntry>()
            for (item in idsPy) {
                val id = item.callAttr("get", "id")?.toString() ?: continue
                if (id !in seenIds) {
                    val url = item.callAttr("get", "url")?.toString() ?: "https://www.youtube.com/watch?v=$id"
                    val title = item.callAttr("get", "title")?.toString() ?: id
                    entries.add(SourceEntry(id, url, title))
                }
            }
            entries
        } catch (e: Exception) {
            Log.w(TAG, "Chaquopy flat extract failed for $sourceUrl: ${e.message}")
            emptyList()
        }
    }

    private fun recordAndQueueEntries(
        db: SQLiteDatabase,
        sourceUrl: String,
        quality: String,
        entries: List<SourceEntry>,
    ) {
        val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }
        val now = sdf.format(Date())

        db.beginTransaction()
        try {
            for (entry in entries) {
                // 1. Record in seen_source_videos
                val seenValues = android.content.ContentValues().apply {
                    put("source_url", sourceUrl)
                    put("video_id", entry.id)
                    put("seen_at", now)
                }
                db.insertWithOnConflict(
                    "seen_source_videos",
                    null,
                    seenValues,
                    SQLiteDatabase.CONFLICT_REPLACE,
                )

                // 2. Queue in downloads table with status = 'pending'
                val downloadId = "obs_${System.currentTimeMillis()}_${entry.id}"
                val config = JSONObject().apply {
                    put("source", "observed")
                    put("quality", quality)
                }.toString()

                val dlValues = android.content.ContentValues().apply {
                    put("id", downloadId)
                    put("url", entry.url)
                    put("title", entry.title)
                    put("status", "pending")
                    put("quality", quality)
                    put("configJson", config)
                    put("attempts", 0)
                    put("bytesDownloaded", 0)
                    put("progress", 0.0)
                    put("timestamp", now)
                    put("updatedAt", now)
                }
                db.insertWithOnConflict(
                    "downloads",
                    null,
                    dlValues,
                    SQLiteDatabase.CONFLICT_IGNORE,
                )
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    private fun postNotification(count: Int) {
        try {
            if (NotificationManagerCompat.from(applicationContext).areNotificationsEnabled()) {
                val intent = Intent(applicationContext, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                }
                val pendingIntent = PendingIntent.getActivity(
                    applicationContext,
                    8812,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )

                val notif = NotificationCompat.Builder(applicationContext, NOTIF_CHANNEL_COMPLETE)
                    .setContentTitle("Grablytic: New Videos Detected")
                    .setContentText("Found $count new video${if (count > 1) "s" else ""} from observed sources queued for download.")
                    .setSmallIcon(android.R.drawable.stat_sys_download_done)
                    .setContentIntent(pendingIntent)
                    .setAutoCancel(true)
                    .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                    .build()

                NotificationManagerCompat.from(applicationContext).notify(8812, notif)
            }
        } catch (_: Exception) {}
    }
}

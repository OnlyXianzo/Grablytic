package com.theonly.grablytic

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.database.sqlite.SQLiteDatabase
import android.util.Base64
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
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.io.ObjectInputStream
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
        // Must match DownloadService.CHANNEL_COMPLETE ("Download complete",
        // HIGH): the old private id "grablytic_downloads_complete" was never
        // created anywhere, so API 26+ silently dropped every background
        // poll notification while logs looked healthy.
        private const val NOTIF_CHANNEL_COMPLETE = "grablytic_complete"

        // ---- Item 6: shared_preferences mapping (defensive mirror) ----
        // Verified against upstream shared_preferences_android (locked at
        // 2.4.23 in pubspec.lock) and the Dart write sites in
        // lib/providers/settings_provider.dart:
        //   * file  = "FlutterSharedPreferences" (plugin SHARED_PREFERENCES_NAME),
        //     i.e. .../shared_prefs/FlutterSharedPreferences.xml, MODE_PRIVATE.
        //   * Dart key K is stored as "flutter.K" (Dart SharedPreferences._prefix).
        // Both are plugin INTERNALS with no stability contract (newer
        // backends support custom fileName/prefix and a DataStore backend
        // this reader could not see), so every read below is
        // contains()-guarded and type-tolerant; unknown state yields the
        // documented Dart-side default, never a crash.
        // Per-key Dart type -> native storage (settings_provider.dart):
        //   scheduleEnabled : bool       -> BOOLEAN (setBool :612, read :300)
        //   scheduleTime    : String     -> String  (setString :616-617, read :301)
        //   scheduleDays    : List<String> -> single String
        //                    "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu"+Base64
        //                    (plugin LIST_IDENTIFIER + Java-serialized list;
        //                    setStringList :621-622, read via getStringList :302).
        //                    A raw getString therefore returns an opaque blob,
        //                    NOT parseable days — see readScheduleDays.
        //   observedSources : String (JSON array) -> String (:667-669, :294).
        private const val PREFS_FILE = "FlutterSharedPreferences"
        private const val KEY_SCHEDULE_ENABLED = "flutter.scheduleEnabled"
        private const val KEY_SCHEDULE_TIME = "flutter.scheduleTime"
        private const val KEY_SCHEDULE_DAYS = "flutter.scheduleDays"
        private const val KEY_OBSERVED_SOURCES = "flutter.observedSources"
        private const val DEFAULT_SCHEDULE_TIME = "22:00"
        private val DEFAULT_SCHEDULE_DAYS = setOf(1, 2, 3, 4, 5)
        private const val LIST_IDENTIFIER = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu"
        private val SCHEDULE_DAYS_CSV = Regex("^[\\d,\\s]+\$")

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
            val snapshot = readPrefsSnapshot()
            if (snapshot == null) {
                Log.i(TAG, "No observed sources configured, skipping")
                return@withContext Result.success()
            }

            // Window check
            if (snapshot.scheduleEnabled &&
                !isWithinScheduleWindow(snapshot.scheduleTime, snapshot.scheduleDays)
            ) {
                Log.i(TAG, "Current time outside scheduled window, skipping poll")
                return@withContext Result.success()
            }
            if (snapshot.enabledSources.isEmpty()) {
                Log.i(TAG, "Observed sources present but none enabled, skipping")
                return@withContext Result.success()
            }

            // Locate grablytic.db. Never CREATE_IF_NECESSARY from here: the
            // file is owned by Dart sqflite (see DownloadDbSweepHelper header).
            val dbFile = grablyticDbFile(applicationContext)
            if (dbFile == null) {
                Log.w(TAG, "Database grablytic.db not found, skipping poll")
                return@withContext Result.success()
            }

            // Phase A — short gated connection: ensure schema, snapshot the
            // seen ledger, close. The connection is closed BEFORE any network
            // I/O so a slow RSS fetch or Chaquopy startup can never hold the
            // DB lock against Dart (the old code held one connection open
            // across all per-source network calls).
            val sourceUrls = snapshot.enabledSources.map { it.url }
            val seenBySource: Map<String, Set<String>> = withGrablyticDb(dbFile) { db ->
                ensureSeenSchema(db)
                readSeenSnapshot(db, sourceUrls)
            }

            // Phase B — network only, no DB held.
            val pending = mutableListOf<PendingSourceResult>()
            var totalNewFound = 0
            for (src in snapshot.enabledSources) {
                if (isStopped) {
                    Log.i(TAG, "Worker stopped by OS constraint or cancellation")
                    break
                }
                val newEntries = checkSource(src.url, seenBySource[src.url] ?: emptySet())
                if (newEntries.isNotEmpty()) {
                    Log.i(TAG, "Found ${newEntries.size} new videos for source: ${src.name} (${src.url})")
                    totalNewFound += newEntries.size
                    pending.add(PendingSourceResult(src.url, src.quality, newEntries))
                }
            }
            if (isStopped) {
                // Nothing was recorded as seen, so the next run re-finds
                // these entries; deterministic queue ids (see
                // recordAndQueueEntries) make that re-run idempotent. Never
                // notify on a cancelled run.
                Log.i(TAG, "Worker stopped after fetch; discarding ${pending.size} source(s) without write")
                return@withContext Result.success()
            }

            // Phase C — short gated connection, writer burst only, no
            // network inside. Persistent BUSY propagates as an exception ->
            // Result.retry() with WorkManager linear backoff (correct here,
            // unlike the boot sweep: this work is deferrable by design).
            if (pending.isNotEmpty()) {
                withGrablyticDb(dbFile) { db ->
                    for (p in pending) {
                        recordAndQueueEntries(db, p.sourceUrl, p.quality, p.entries)
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

    // ---- Item 6: defensive prefs snapshot ----

    private data class ParsedSource(val url: String, val name: String, val quality: String)

    private data class PollPrefs(
        val scheduleEnabled: Boolean,
        val scheduleTime: String,
        val scheduleDays: Set<Int>,
        val enabledSources: List<ParsedSource>,
    )

    private data class PendingSourceResult(
        val sourceUrl: String,
        val quality: String,
        val entries: List<SourceEntry>,
    )

    /**
     * Reads everything the worker needs from FlutterSharedPreferences in one
     * place. Returns null when there is nothing to poll (absent/unparseable
     * `observedSources`) — both map to Result.success(), never retry, so a
     * corrupt value cannot poison the WorkManager queue. Per-key
     * ClassCastExceptions (native type != expected, e.g. after a plugin
     * storage-format change) fall back to the Dart-side default + Log.w.
     */
    private fun readPrefsSnapshot(): PollPrefs? {
        try {
            if (!applicationContext.getSharedPrefsFile(PREFS_FILE).exists()) {
                Log.i(TAG, "No $PREFS_FILE.xml yet (fresh install or Dart never saved prefs); using defaults")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Prefs file probe failed, reading with defaults: ${e.message}")
        }
        val prefs = try {
            applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        } catch (e: Exception) {
            Log.e(TAG, "Cannot open $PREFS_FILE, skipping poll: ${e.message}")
            return null
        }

        val observedSourcesJson = getStringSafe(prefs, KEY_OBSERVED_SOURCES, null)
        if (observedSourcesJson.isNullOrEmpty()) return null

        val enabledSources = try {
            val sourcesArray = JSONArray(observedSourcesJson)
            List(sourcesArray.length()) { i -> sourcesArray.optJSONObject(i) }
                .filter { o ->
                    o != null && o.optBoolean("enabled", true) &&
                        o.optString("url", "").trim().isNotEmpty()
                }
                .map { o ->
                    ParsedSource(
                        url = o!!.optString("url").trim(),
                        name = o.optString("name", "Channel"),
                        quality = o.optString("quality", "best"),
                    )
                }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to parse observedSources JSON: ${e.message}")
            return null
        }

        return PollPrefs(
            scheduleEnabled = getBooleanSafe(prefs, KEY_SCHEDULE_ENABLED, false),
            scheduleTime = getStringSafe(prefs, KEY_SCHEDULE_TIME, null)
                ?.takeIf { it.isNotBlank() } ?: DEFAULT_SCHEDULE_TIME,
            scheduleDays = readScheduleDays(prefs),
            enabledSources = enabledSources,
        )
    }

    private fun getBooleanSafe(prefs: SharedPreferences, key: String, default: Boolean): Boolean {
        if (!prefs.contains(key)) return default
        return try {
            prefs.getBoolean(key, default)
        } catch (_: ClassCastException) {
            Log.w(TAG, "$key has unexpected native type; using default=$default")
            default
        }
    }

    private fun getStringSafe(prefs: SharedPreferences, key: String, default: String?): String? {
        if (!prefs.contains(key)) return default
        return try {
            prefs.getString(key, default)
        } catch (_: ClassCastException) {
            Log.w(TAG, "$key has unexpected native type; using default")
            default
        }
    }

    /**
     * Reads `scheduleDays` tolerating every known native encoding, newest first:
     *  1. StringSet (pre-Pigeon-era installs; the plugin itself migrates these
     *     on Dart read — mirror that tolerance, never migrate from here).
     *  2. Raw JSON array / CSV digits (hand-written or legacy values; the
     *     previous worker version accepted both — keep accepting).
     *  3. Plugin LIST_IDENTIFIER blob (what Dart actually writes today via
     *     setStringList): an optional "!" + JSON array (newer Dart-side
     *     encoding) or Base64 Java-serialized list (platform encoding).
     * Anything else -> DEFAULT_SCHEDULE_DAYS (Mon-Fri, matching Dart
     * settings_provider.dart:302) with a loud log. Never throws.
     */
    private fun readScheduleDays(prefs: SharedPreferences): Set<Int> {
        try {
            prefs.getStringSet(KEY_SCHEDULE_DAYS, null)?.let { set ->
                val days = set.mapNotNull { it.trim().toIntOrNull() }.toSet()
                if (days.isNotEmpty()) return days
            }
        } catch (_: ClassCastException) {
            // Current encoding is a String blob; fall through.
        } catch (e: Exception) {
            Log.w(TAG, "scheduleDays StringSet read failed: ${e.message}")
        }

        val raw = try {
            prefs.getString(KEY_SCHEDULE_DAYS, null)
        } catch (_: ClassCastException) {
            null
        } catch (e: Exception) {
            Log.w(TAG, "scheduleDays String read failed: ${e.message}")
            null
        }
        if (raw.isNullOrBlank()) {
            Log.i(TAG, "scheduleDays absent; defaulting to Mon-Fri $DEFAULT_SCHEDULE_DAYS")
            return DEFAULT_SCHEDULE_DAYS
        }
        val text = raw.trim()
        if (text.startsWith("[")) {
            try {
                val arr = JSONArray(text)
                val days = List(arr.length()) { arr.optString(it) }
                    .mapNotNull { it.trim().toIntOrNull() }.toSet()
                if (days.isNotEmpty()) return days
            } catch (e: Exception) {
                Log.w(TAG, "scheduleDays JSON parse failed: ${e.message}")
            }
        } else if (SCHEDULE_DAYS_CSV.matches(text)) {
            val days = text.split(",").mapNotNull { it.trim().toIntOrNull() }.toSet()
            if (days.isNotEmpty()) return days
        } else {
            val decoded = decodePlatformListString(text)
            val days = decoded?.mapNotNull { it.trim().toIntOrNull() }?.toSet() ?: emptySet()
            if (days.isNotEmpty()) return days
        }
        Log.w(
            TAG,
            "Unparseable scheduleDays (len=${text.length}, prefix='${text.take(24)}'); " +
                "defaulting to Mon-Fri $DEFAULT_SCHEDULE_DAYS. Full value withheld from log.",
        )
        return DEFAULT_SCHEDULE_DAYS
    }

    /**
     * Best-effort decode of the plugin's StringList blob: LIST_IDENTIFIER +
     * either "!" + JSON array or Base64(Java-serialized ArrayList) — mirrors
     * shared_preferences_android ListEncoder. Returns null when undecodable.
     * Runs on app-private MODE_PRIVATE data (backup disabled in the
     * manifest), so ObjectInputStream only ever sees bytes our own Dart side
     * wrote; any failure still falls back to defaults, never a crash.
     */
    private fun decodePlatformListString(raw: String): List<String>? {
        if (!raw.startsWith(LIST_IDENTIFIER)) return null
        val payload = raw.substring(LIST_IDENTIFIER.length)
        if (payload.startsWith("!")) {
            return try {
                val arr = JSONArray(payload.substring(1))
                List(arr.length()) { arr.optString(it) }
            } catch (_: Exception) {
                null
            }
        }
        return try {
            val bytes = Base64.decode(payload, Base64.DEFAULT)
            ObjectInputStream(ByteArrayInputStream(bytes)).use { ois ->
                @Suppress("UNCHECKED_CAST")
                (ois.readObject() as? List<*>)?.map { it.toString() }
            }
        } catch (_: Exception) {
            null
        }
    }

    /** Schema ensure for the seen ledger; runs on the short Phase-A connection. */
    private fun ensureSeenSchema(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS seen_source_videos (
              source_url TEXT NOT NULL,
              video_id TEXT NOT NULL,
              seen_at TEXT NOT NULL,
              PRIMARY KEY (source_url, video_id)
            )
            """.trimIndent(),
        )
        db.execSQL("CREATE INDEX IF NOT EXISTS idx_seen_source_url ON seen_source_videos(source_url)")
    }

    /** Bulk-reads the seen ledger for exactly the sources about to be polled. */
    private fun readSeenSnapshot(db: SQLiteDatabase, sourceUrls: List<String>): Map<String, Set<String>> {
        val out = mutableMapOf<String, MutableSet<String>>()
        if (sourceUrls.isEmpty()) return out
        val placeholders = sourceUrls.joinToString(",") { "?" }
        db.rawQuery(
            "SELECT source_url, video_id FROM seen_source_videos WHERE source_url IN ($placeholders)",
            sourceUrls.toTypedArray(),
        ).use { c ->
            val urlIdx = c.getColumnIndex("source_url")
            val idIdx = c.getColumnIndex("video_id")
            while (c.moveToNext()) {
                out.getOrPut(c.getString(urlIdx)) { mutableSetOf() }.add(c.getString(idIdx))
            }
        }
        return out
    }

    private fun isWithinScheduleWindow(scheduleTime: String, days: Set<Int>): Boolean {
        val cal = Calendar.getInstance()
        val dayOfWeek = cal.get(Calendar.DAY_OF_WEEK)
        val isoWeekday = if (dayOfWeek == Calendar.SUNDAY) 7 else dayOfWeek - 1

        if (!days.contains(isoWeekday)) return false

        val parts = scheduleTime.split(":")
        if (parts.size != 2) {
            Log.w(TAG, "Malformed scheduleTime '$scheduleTime'; ignoring time gate")
            return true
        }
        val h = parts[0].toIntOrNull()
        val m = parts[1].toIntOrNull()
        if (h == null || m == null) {
            Log.w(TAG, "Malformed scheduleTime '$scheduleTime'; ignoring time gate")
            return true
        }
        if (h !in 0..23 || m !in 0..59) {
            Log.w(TAG, "Out-of-range scheduleTime '$scheduleTime'; ignoring time gate")
            return true
        }

        val startMinutes = h * 60 + m
        val currentMinutes = cal.get(Calendar.HOUR_OF_DAY) * 60 + cal.get(Calendar.MINUTE)
        return currentMinutes >= startMinutes
    }

    /**
     * Item 6: pure-network filter. Seen ids come from the Phase-A snapshot,
     * never from a live DB handle, so slow RSS/Chaquopy calls hold no lock.
     */
    private fun checkSource(sourceUrl: String, seenIds: Set<String>): List<SourceEntry> {
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

                // 2. Queue in downloads table with status = 'pending'.
                // Deterministic id (no wall-clock): a rerun after a failed or
                // cancelled run re-finds the same entries, and with
                // CONFLICT_IGNORE + stable ids the re-run is a no-op instead
                // of a duplicate queue row. String.hashCode is JLS-specified
                // (stable across processes); '-' escaped since ids feed LIKE
                // filters elsewhere. (Deliberately NOT Integer.toUnsignedString:
                // that is API 26+ and minSdk here is 24.)
                val sourceTag = sourceUrl.hashCode().toString().replace('-', 'n')
                val safeVideoId = entry.id.replace(Regex("[^A-Za-z0-9_-]"), "_")
                val downloadId = "obs_${sourceTag}_${safeVideoId}"
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

    private fun ensureCompleteChannel() {
        try {
            if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.O) return
            val mgr = applicationContext.getSystemService(
                android.app.NotificationManager::class.java) ?: return
            if (mgr.getNotificationChannel(NOTIF_CHANNEL_COMPLETE) == null) {
                mgr.createNotificationChannel(
                    android.app.NotificationChannel(
                        NOTIF_CHANNEL_COMPLETE,
                        "Download complete",
                        android.app.NotificationManager.IMPORTANCE_HIGH,
                    ).apply { description = "Alerts when a download finishes" },
                )
            }
        } catch (_: Exception) {
        }
    }

    private fun postNotification(count: Int) {
        try {
            ensureCompleteChannel()
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

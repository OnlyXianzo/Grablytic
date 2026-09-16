package com.theonly.grablytic

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import com.chaquo.python.PyObject
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import kotlinx.coroutines.*
import java.io.File

/**
 * Chaquopy callback contract for engine → Kotlin event delivery.
 * A public interface (not an anonymous `object : Any()`) so R8/ProGuard
 * cannot obfuscate or strip `onEvent` in release builds (re-audit #2).
 * Belt and braces: @Keep annotations (release builds run R8 full mode,
 * which has silently eaten proxied callbacks before).
 */
@androidx.annotation.Keep
interface EngineEventListener {
    @androidx.annotation.Keep
    fun onEvent(eventJson: String)
}

class MainActivity : FlutterActivity() {
    private val ENGINE_CHANNEL = "com.theonly.grablytic/engine"
    private val PROGRESS_CHANNEL = "com.theonly.grablytic/progress"

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private var methodChannel: MethodChannel? = null
    // T2-6: FIFO of share URLs (was a single nullable var — two rapid
    // shares overwrote, the second silently lost). Bounded: overflow evicts
    // the oldest. Thread-safe for onNewIntent vs method-channel threads.
    private val sharedUrls = java.util.concurrent.ConcurrentLinkedQueue<String>()
    private var py: Python? = null

    private var dataDir: String? = null
    private var outputDir: String? = null
    private var ffmpegPath: String? = null
    private var aria2cPath: String? = null
    private var pendingNotifResult: MethodChannel.Result? = null
    private var notifPromptShown = false

    companion object {
        private const val REQ_POST_NOTIFICATIONS = 4101
        // T2-6: backlog bound for rapid shares (mirrors Dart _maxPendingShares).
        private const val MAX_QUEUED_SHARES = 50
        // Terminals missed per detach gap (mirrors the engine queue vocabulary).
        private const val MAX_UNDELIVERED_TERMINALS = 50
        private val TERMINAL_EVENTS = setOf("finished", "error", "cancelled")

        val activeCallbacks = java.util.concurrent.ConcurrentHashMap<String, Any>()
        @Volatile
        var eventSink: EventChannel.EventSink? = null
        private val terminalLock = Any()
        private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

        // Process-wide missed-terminal buffer (see instance comment above).
        // Insertion-ordered eviction: the queue mirrors map keys oldest
        // first, so overflow evicts the OLDEST id — never a random one
        // (the old ConcurrentHashMap.keys.firstOrNull() was unordered).
        private val undeliveredTerminals =
            java.util.concurrent.ConcurrentHashMap<String, String>()
        private val undeliveredOrder =
            java.util.concurrent.ConcurrentLinkedQueue<String>()

        // Stash one terminal for the next onListen. Same-id re-arrival
        // refreshes recency instead of duplicating. Never throws.
        private fun bufferTerminal(id: String, eventJson: String) {
            synchronized(terminalLock) {
                try {
                    if (undeliveredTerminals.containsKey(id)) {
                        undeliveredOrder.remove(id)
                    } else {
                        while (undeliveredTerminals.size >= MAX_UNDELIVERED_TERMINALS) {
                            val oldest = undeliveredOrder.poll() ?: break
                            undeliveredTerminals.remove(oldest)
                        }
                    }
                    undeliveredTerminals[id] = eventJson
                    undeliveredOrder.offer(id)
                } catch (_: Exception) {
                }
            }
        }

        // Flush oldest-first to a live sink. Each entry is removed only
        // after a successful success() call, so a mid-flush failure keeps
        // the unsent tail buffered instead of dropping it (the old code
        // cleared before the loop and broke on first throw).
        private fun flushTerminals(events: EventChannel.EventSink) {
            synchronized(terminalLock) {
                while (true) {
                    val id = undeliveredOrder.peek() ?: return
                    val json = undeliveredTerminals[id] ?: run {
                        undeliveredOrder.remove(id)
                        continue
                    }
                    try {
                        events.success(json)
                    } catch (_: Exception) {
                        return
                    }
                    undeliveredOrder.remove(id)
                    undeliveredTerminals.remove(id)
                }
            }
        }

        fun reportTerminalTimeout(id: String) {
            val eventJson = org.json.JSONObject().apply {
                put("type", "event")
                put("download_id", id)
                put("event", "error")
                put("error_type", "ERROR_TIMEOUT")
                put("error_message", "Download paused: background execution limit reached. Re-open app to resume.")
                put("suggests_vpn", false)
            }.toString()

            bufferTerminal(id, eventJson)
            mainHandler.post {
                eventSink?.let { flushTerminals(it) }
            }
        }

        // Media-store visibility scan (companion-static with explicit
        // context/dir: progress listeners outlive activity recreations and
        // must not capture the Activity). Files land via raw rename
        // (yt-dlp MoveFiles), which never notifies MediaStore — without
        // this scan they exist on disk but stay invisible in every media
        // browser. scanFileExact hits the finished path from the engine
        // event (never thumbnail sidecars); the recursive walk is the
        // self-healing fallback (real files land in Video/<name> and
        // Audio/<name> subfolders). Never throws.
        private fun scanRecentMedia(ctx: android.content.Context, outDir: String?) {
            try {
                val root = outDir?.let(::File)?.takeIf { it.isDirectory } ?: return
                val cutoff = System.currentTimeMillis() - 2 * 60 * 60 * 1000
                val files = ArrayList<File>()
                collectRecentMedia(root, cutoff, files)
                files.forEach { f ->
                    try {
                        android.media.MediaScannerConnection.scanFile(
                            ctx, arrayOf(f.absolutePath), null, null,
                        )
                    } catch (_: Exception) {
                    }
                }
            } catch (_: Exception) {
            }
        }

        private fun collectRecentMedia(dir: File, cutoff: Long, out: ArrayList<File>) {
            val kids = try {
                dir.listFiles()
            } catch (_: Exception) {
                null
            } ?: return
            for (f in kids) {
                try {
                    if (f.isDirectory) {
                        // Skip hidden/cache dirs ( temp segments, .tmp work files).
                        if (!f.name.startsWith(".")) collectRecentMedia(f, cutoff, out)
                    } else if (f.isFile && f.lastModified() >= cutoff &&
                        f.extension.lowercase() in MEDIA_EXTS &&
                        !isThumbnailSidecar(f)
                    ) {
                        out.add(f)
                    }
                } catch (_: Exception) {
                }
            }
        }

        private fun scanFileExact(ctx: android.content.Context, path: String?) {
            try {
                if (path.isNullOrEmpty()) return
                val f = File(path)
                if (!f.isFile) return
                if (f.extension.lowercase() !in MEDIA_EXTS) return
                android.media.MediaScannerConnection.scanFile(
                    ctx, arrayOf(f.absolutePath), null, null,
                )
            } catch (_: Exception) {
            }
        }

        private fun isThumbnailSidecar(f: File): Boolean {
            // writethumbnail sidecars share the media basename (<name>.jpg next
            // to <name>.mp4). A same-basename media file means "thumbnail".
            if (f.extension.lowercase() !in THUMB_EXTS) return false
            val base = f.nameWithoutExtension
            val parent = try { f.parentFile } catch (_: Exception) { null } ?: return false
            return MEDIA_EXTS.any { ext ->
                try {
                    File(parent, "$base.$ext").isFile
                } catch (_: Exception) {
                    false
                }
            }
        }

        private val MEDIA_EXTS = setOf(
            "mkv", "mp4", "webm", "m4v", "mov", "avi", "3gp", "3g2", "ts", "mts",
            "mpg", "mpeg", "m4a", "mp3", "opus", "ogg", "oga", "weba", "wav",
            "aac", "m4b", "aiff", "aif", "flac",
        )
        private val THUMB_EXTS = setOf("jpg", "jpeg", "png", "webp")
    }

    private fun handleSendText(intent: Intent?) {
        if (intent == null) return
        if (intent.action == Intent.ACTION_SEND && intent.type == "text/plain") {
            val sharedText = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return
            // SEC-03: cap inbound share text — a multi-MB EXTRA_TEXT from a
            // malicious app would otherwise ride into regex + UI state.
            // 8 KB still fits any real URL several times over.
            if (sharedText.length > 8192) return
            val urlRegex = "(https?://[\\w\\d:#@%/;$~()'*&+-=\\?\\.\\!\\[\\]]+)".toRegex()
            val match = urlRegex.find(sharedText)
            if (match != null) {
                val url = match.value
                while (sharedUrls.size >= MAX_QUEUED_SHARES) sharedUrls.poll()
                sharedUrls.offer(url)
                scope.launch(Dispatchers.Main) {
                    methodChannel?.invokeMethod("intent/shared_url", mapOf("url" to url))
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleSendText(intent)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_POST_NOTIFICATIONS) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            try {
                pendingNotifResult?.success(mapOf("success" to true, "granted" to granted))
            } catch (_: Exception) {
            }
            pendingNotifResult = null
        }
    }

    private fun notificationsGranted(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return androidx.core.content.ContextCompat.checkSelfPermission(
            this, android.Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun batteryExempt(): Boolean {
        return try {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            pm.isIgnoringBatteryOptimizations(packageName)
        } catch (_: Exception) {
            false
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (!Python.isStarted()) {
            Python.start(AndroidPlatform(applicationContext))
        }
        py = Python.getInstance()
        setupChannels(flutterEngine)
        handleSendText(intent)
    }

    private fun pyJson(obj: PyObject): String {
        val python = py ?: return "{}"
        return try {
            val jsonMod = python.getModule("json")
            jsonMod.callAttr("dumps", obj).toString()
        } catch (_: Exception) {
            "{}"
        }
    }

    /**
     * Serializes a config Map to a JSON string for Python. Chaquopy delivers
     * Kotlin/Java Maps as live java.util.HashMap proxies — NOT real Python
     * mappings — so `{**config}` in Python dies with
     * "TypeError: 'HashMap' object is not a mapping". JSON crosses cleanly
     * (recursive, null-safe) and Python coerces it back via coerce_config().
     */
    private fun configJson(config: Map<String, Any>?): String {
        if (config == null) return "{}"
        return try {
            org.json.JSONObject(config as Map<*, *>).toString()
        } catch (_: Exception) {
            "{}"
        }
    }

    @androidx.annotation.Keep
    private class ProcessEngineEventListener(
        private val appContext: android.content.Context,
        private val outDir: String?,
    ) : EngineEventListener {
        private var noSinkWarned = false

        override fun onEvent(eventJson: String) {
            val terminalId = try {
                val o = org.json.JSONObject(eventJson)
                if (o.optString("type") == "event" && o.optString("event") in TERMINAL_EVENTS) {
                    o.optString("download_id").takeIf { it.isNotEmpty() }
                } else null
            } catch (_: Exception) { null }

            try {
                val obj = org.json.JSONObject(eventJson)
                if (obj.optString("type") == "event") {
                    val id = obj.optString("download_id")
                    if (id.isNotEmpty()) {
                        when (obj.optString("event")) {
                            "downloading" -> {
                                val dl = obj.optLong("downloaded_bytes", 0)
                                val total = obj.optLong("total_bytes", 0)
                                val speed = obj.optLong("speed", 0)
                                val pct = if (total > 0) ((dl * 100) / total).toInt().coerceIn(0, 99) else -1
                                DownloadService.update(appContext, id, pct, speedBps = speed, downloadedBytes = dl, totalBytes = total)
                            }
                            "postprocessing" -> {
                                DownloadService.updateStage(appContext, id, obj.optString("stage_label", "Processing..."))
                            }
                            "finished", "error", "cancelled" -> {
                                activeCallbacks.remove(id)
                                when (obj.optString("event")) {
                                    "finished" -> {
                                        DownloadService.finished(appContext, id)
                                        scanFileExact(appContext, obj.optString("file_path", null))
                                        scanRecentMedia(appContext, outDir)
                                    }
                                    "error" -> DownloadService.failed(appContext, id, obj.optString("error_message", null).takeIf { it.isNotEmpty() })
                                    else -> DownloadService.done(appContext, id, true)
                                }
                            }
                        }
                    }
                }
            } catch (_: Exception) {}

            if (terminalId != null) {
                // 1. Buffer synchronously FIRST: guarantees survival across any destroy/cancel
                bufferTerminal(terminalId, eventJson)
                // 2. Dispatch flush to Main thread via Handler
                mainHandler.post {
                    eventSink?.let { flushTerminals(it) }
                }
            } else {
                val sink = eventSink
                if (sink != null) {
                    mainHandler.post {
                        try { eventSink?.success(eventJson) } catch (_: Exception) {}
                    }
                } else if (!noSinkWarned) {
                    noSinkWarned = true
                    android.util.Log.w("GrablyticEngine", "EventChannel sink null — Flutter is not listening")
                }
            }
        }
    }

    private fun setupChannels(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ENGINE_CHANNEL)
        methodChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "intent/get_shared" -> {
                    // Pops one URL per call (null when empty) so the Dart
                    // drain loop collects every queued share, in order.
                    result.success(mapOf("url" to sharedUrls.poll()))
                }
                // Open a URL with the system resolver (ACTION_VIEW): if an
                // app registered for the host (e.g. the GitHub app for
                // github.com links) Android offers it, otherwise the browser.
                // http(s) + mailto only, fail-closed. No extra dependency.
                "intent/open_url" -> {
                    val url = call.argument<String>("url")
                    try {
                        val uri = android.net.Uri.parse(url)
                        val scheme = uri?.scheme?.lowercase()
                        if (uri == null || (scheme != "http" && scheme != "https" && scheme != "mailto")) {
                            result.success(mapOf("success" to false, "error" to "only http(s)/mailto URLs"))
                        } else {
                            val view = Intent(Intent.ACTION_VIEW, uri).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            if (view.resolveActivity(packageManager) != null) {
                                startActivity(view)
                                result.success(mapOf("success" to true))
                            } else {
                                result.success(mapOf("success" to false, "error" to "no handler"))
                            }
                        }
                    } catch (e: Exception) {
                        result.success(mapOf("success" to false, "error" to (e.message ?: "open failed")))
                    }
                }
                "paths/set" -> {
                    this.dataDir = call.argument<String>("data_dir")
                    val outputDir = call.argument<String>("output_dir")
                    this.outputDir = outputDir
                    val dartFfmpegPath = call.argument<String>("ffmpeg_path")
                    val cacheDir = call.argument<String>("cache_dir")
                    val cookiesPath = call.argument<String>("cookies_path")
                    this.aria2cPath = call.argument<String>("aria2c_path")
                    val dartDenoPath = call.argument<String>("deno_path")
                    val poToken = call.argument<String>("po_token")

                    // Bundled jniLibs binaries win: only APK-origin files are
                    // executable on targetSdk > 28. Dart-sent bin/ paths are
                    // kept as fallback (desktop flows, -PskipNativePackages).
                    // Resolution runs on Dispatchers.IO below (file I/O +
                    // --version probes must stay off the main thread).
                    scope.launch(Dispatchers.IO) {
                        val bins = try {
                            BinaryPackageManager.init(applicationContext)
                        } catch (_: Exception) {
                            emptyMap()
                        }
                        val allLdDirs = listOfNotNull(
                            bins["ffmpeg"]?.ldLibDir,
                            bins["deno"]?.ldLibDir,
                            bins["node"]?.ldLibDir,
                            applicationContext.applicationInfo.nativeLibraryDir,
                        ).distinct()
                        val binStatuses = BinaryPackageManager.status(bins, allLdDirs).associateBy { it.name }
                        for (s in binStatuses.values) {
                            android.util.Log.i(
                                "BinaryPackages",
                                "${s.name}: ok=${s.ok} version=${s.version} ${s.detail}",
                            )
                        }
                        val ffmpegBin = bins["ffmpeg"]?.takeIf { binStatuses["ffmpeg"]?.ok == true }
                        val denoBin = bins["deno"]?.takeIf { binStatuses["deno"]?.ok == true }
                        val nodeBin = bins["node"]?.takeIf { binStatuses["node"]?.ok == true }
                        ffmpegPath = ffmpegBin?.executable ?: dartFfmpegPath
                        val ffmpegLdPath = allLdDirs.joinToString(":").takeIf { it.isNotEmpty() }
                        val resolvedNodePath = nodeBin?.executable
                        val resolvedDenoPath = denoBin?.executable ?: dartDenoPath
                        if (denoBin == null && nodeBin == null) {
                            // No working JS runtime (e.g. armeabi-v7a ships
                            // no deno and node probe failed): the Dart-sent
                            // bin/ fallback above is NOT executable on
                            // targetSdk > 28, so YouTube extraction will
                            // fail at download time. Say so now in logcat
                            // instead of surfacing minutes later as a
                            // generic engine exec failure.
                            android.util.Log.w(
                                "BinaryPackages",
                                "no working JS runtime (deno/node absent or probe-failed); " +
                                    "YouTube EJS challenges cannot run on this device",
                            )
                        }
                        try {
                            val python = py ?: return@launch
                            val engine = python.getModule("grablytic_engine")
                            engine.callAttr("set_paths", dataDir, outputDir, ffmpegPath, cacheDir, cookiesPath, aria2cPath, resolvedDenoPath, poToken, ffmpegLdPath, resolvedNodePath)
                            withContext(Dispatchers.Main) { result.success(mapOf("success" to true)) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) { result.error("ERROR_INVALID_PATH", e.message, null) }
                        }
                    }
                }
                "engine/bootstrap" -> {
                    scope.launch(Dispatchers.IO) {
                        try {
                            val python = py ?: return@launch
                            val engine = python.getModule("grablytic_engine")
                            val bootstrapResult = engine.callAttr("bootstrap")

                            // Force executable flag on freshly downloaded binaries
                            ffmpegPath?.let { path ->
                                val file = File(path)
                                if (file.exists()) file.setExecutable(true, false)
                            }
                            aria2cPath?.let { path ->
                                val file = File(path)
                                if (file.exists()) file.setExecutable(true, false)
                            }
                            dataDir?.let { dir ->
                                val ffmpegFile = File(dir, "bin/ffmpeg")
                                if (ffmpegFile.exists()) ffmpegFile.setExecutable(true, false)
                                val aria2cFile = File(dir, "bin/aria2c")
                                if (aria2cFile.exists()) aria2cFile.setExecutable(true, false)
                            }

                            val jsonStr = pyJson(bootstrapResult)
                            withContext(Dispatchers.Main) { result.success(jsonStr) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) { result.error("ERROR_BOOTSTRAP_FAILED", e.message, null) }
                        }
                    }
                }
                "download/start" -> {
                    val url = call.argument<String>("url")
                    val downloadId = call.argument<String>("download_id")
                    val config = call.argument<Map<String, Any>>("config")
                    val networkType = call.argument<String>("network_type")

                    scope.launch(Dispatchers.IO) {
                        try {
                            val python = py ?: return@launch
                            val engine = python.getModule("grablytic_engine")

                            val eventCallback = ProcessEngineEventListener(applicationContext, outputDir)
                            if (downloadId != null) {
                                activeCallbacks[downloadId] = eventCallback
                            }

                            // Keep-alive: user gesture (foreground) → dataSync FGS.
                            // Completion/failure alerts are NOT FGS-exempt, so
                            // make sure POST_NOTIFICATIONS is granted while we
                            // still have a foreground moment to ask in (once —
                            // repeat prompts nag and the OS auto-denies them).
                            if (!notifPromptShown && !notificationsGranted() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                notifPromptShown = true
                                try {
                                    androidx.core.app.ActivityCompat.requestPermissions(
                                        this@MainActivity,
                                        arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                                        REQ_POST_NOTIFICATIONS,
                                    )
                                } catch (_: Exception) {
                                }
                            }
                            val showAlert = try {
                                @Suppress("UNCHECKED_CAST")
                                (config as? Map<*, *>)?.get("completion_alerts") as? Boolean
                            } catch (_: Exception) {
                                null
                            } ?: true
                            try {
                                val title = try {
                                    android.net.Uri.parse(url).host ?: url
                                } catch (_: Exception) {
                                    downloadId
                                }
                                DownloadService.start(
                                    this@MainActivity,
                                    downloadId ?: "unknown",
                                    title ?: "Download",
                                    showAlert,
                                )
                            } catch (e: Exception) {
                                android.util.Log.w("GrablyticEngine", "DownloadService.start failed: ${e.message}")
                            }

                            val startResult = engine.callAttr("start_download", url, downloadId, configJson(config), networkType, eventCallback)
                            val jsonStr = pyJson(startResult)
                            if (downloadId != null && !jsonStr.contains("\"success\": true") && !jsonStr.contains("\"success\":true")) {
                                activeCallbacks.remove(downloadId)
                            }
                            withContext(Dispatchers.Main) { result.success(jsonStr) }
                        } catch (e: Exception) {
                            if (downloadId != null) {
                                activeCallbacks.remove(downloadId)
                            }
                            withContext(Dispatchers.Main) { result.error("ERROR_START_FAILED", e.message, null) }
                        }
                    }
                }
                "download/clear_archive" -> {
                    scope.launch(Dispatchers.IO) {
                        try {
                            val python = py ?: return@launch
                            val engine = python.getModule("grablytic_engine")
                            val cleared = engine.callAttr("clear_download_archive")
                            val jsonStr = pyJson(cleared)
                            withContext(Dispatchers.Main) { result.success(jsonStr) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) { result.error("ERROR_ARCHIVE_FAILED", e.message, null) }
                        }
                    }
                }
                "download/queue_status" -> {
                    scope.launch(Dispatchers.IO) {
                        try {
                            val python = py ?: return@launch
                            val engine = python.getModule("grablytic_engine")
                            val status = engine.callAttr("get_queue_status")
                            val jsonStr = pyJson(status)
                            withContext(Dispatchers.Main) { result.success(jsonStr) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) { result.error("ERROR_QUEUE_FAILED", e.message, null) }
                        }
                    }
                }
                "download/set_concurrency" -> {
                    val maxConcurrent = call.argument<Int>("max_concurrent") ?: 2
                    scope.launch(Dispatchers.IO) {
                        try {
                            val python = py ?: return@launch
                            val engine = python.getModule("grablytic_engine")
                            val updated = engine.callAttr("set_max_concurrent", maxConcurrent)
                            val jsonStr = pyJson(updated)
                            withContext(Dispatchers.Main) { result.success(jsonStr) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) { result.error("ERROR_CONCURRENCY_FAILED", e.message, null) }
                        }
                    }
                }
                "download/cancel" -> {
                    val downloadId = call.argument<String>("download_id")
                    if (downloadId != null) {
                        activeCallbacks.remove(downloadId)
                    }
                    scope.launch(Dispatchers.IO) {
                        try {
                            val python = py ?: return@launch
                            val engine = python.getModule("grablytic_engine")
                            val cancelResult = engine.callAttr("cancel_download", downloadId)
                            val jsonStr = pyJson(cancelResult)
                            withContext(Dispatchers.Main) { result.success(jsonStr) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) { result.error("ERROR_CANCEL_FAILED", e.message, null) }
                        }
                    }
                }
                "formats/get" -> {
                    val url = call.argument<String>("url")
                    val config = call.argument<Map<String, Any>>("config")
                    scope.launch(Dispatchers.IO) {
                        try {
                            val python = py ?: return@launch
                            val engine = python.getModule("grablytic_engine")
                            val formatsResult = engine.callAttr("get_formats", url, configJson(config))
                            val jsonStr = pyJson(formatsResult)
                            withContext(Dispatchers.Main) { result.success(jsonStr) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) { result.error("ERROR_FORMATS_FAILED", e.message, null) }
                        }
                    }
                }
                "playlist/info" -> {
                    val url = call.argument<String>("url")
                    val config = call.argument<Map<String, Any>>("config")
                    scope.launch(Dispatchers.IO) {
                        try {
                            val python = py ?: return@launch
                            val engine = python.getModule("grablytic_engine")
                            val playlistResult = engine.callAttr("get_playlist_info", url, configJson(config))
                            val jsonStr = pyJson(playlistResult)
                            withContext(Dispatchers.Main) { result.success(jsonStr) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) { result.error("ERROR_PLAYLIST_FAILED", e.message, null) }
                        }
                    }
                }
                "search/query" -> {
                    val query = call.argument<String>("query") ?: ""
                    val site = call.argument<String>("site") ?: "youtube"
                    val limit = call.argument<Int>("limit") ?: 20
                    val config = call.argument<Map<String, Any>>("config")
                    scope.launch(Dispatchers.IO) {
                        try {
                            val python = py ?: return@launch
                            val engine = python.getModule("grablytic_engine")
                            val searchResult = engine.callAttr("search_query", query, site, limit, configJson(config))
                            val jsonStr = pyJson(searchResult)
                            withContext(Dispatchers.Main) { result.success(jsonStr) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) { result.error("ERROR_SEARCH_FAILED", e.message, null) }
                        }
                    }
                }
                "resume/scan" -> {
                    val cacheDir = call.argument<String>("cache_dir")
                    scope.launch(Dispatchers.IO) {
                        try {
                            val python = py ?: return@launch
                            val engine = python.getModule("grablytic_engine")
                            val resumeResult = engine.callAttr("scan_resume_candidates", cacheDir)
                            val jsonStr = pyJson(resumeResult)
                            withContext(Dispatchers.Main) { result.success(jsonStr) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) { result.error("ERROR_RESUME_FAILED", e.message, null) }
                        }
                    }
                }
                "resume/report" -> {
                    val cacheDir = call.argument<String>("cache_dir")
                    val filepath = call.argument<String>("filepath")
                    val success = call.argument<Boolean>("success") ?: false
                    scope.launch(Dispatchers.IO) {
                        try {
                            val python = py ?: return@launch
                            val engine = python.getModule("grablytic_engine")
                            val reportResult = engine.callAttr(
                                "report_resume_attempt", cacheDir, filepath, success)
                            val jsonStr = pyJson(reportResult)
                            withContext(Dispatchers.Main) { result.success(jsonStr) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) { result.error("ERROR_RESUME_FAILED", e.message, null) }
                        }
                    }
                }
                "system/battery_status" -> {
                    result.success(mapOf("success" to true, "supported" to true, "exempt" to batteryExempt()))
                }
                "system/battery_request" -> {
                    // Play policy: exemption prompts must be user-initiated
                    // with rationale — this handler only runs from the
                    // Settings toggle. Direct request first, system screen
                    // fallback (e.g. permission missing on some ROMs).
                    var launched = false
                    try {
                        val intent = Intent(
                            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                            android.net.Uri.parse("package:$packageName"),
                        )
                        startActivity(intent)
                        launched = true
                    } catch (_: Exception) {
                        try {
                            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                            launched = true
                        } catch (_: Exception) {
                        }
                    }
                    result.success(mapOf("success" to launched))
                }
                "system/notification_status" -> {
                    val supported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                    result.success(mapOf("success" to true, "supported" to supported, "granted" to notificationsGranted()))
                }
                "system/notification_settings" -> {
                    // Denial recovery: deep-link to this app's notification
                    // settings (permanently-denied / "don't ask again" path).
                    var launched = false
                    try {
                        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                            }
                        } else {
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                android.net.Uri.parse("package:$packageName"),
                            )
                        }
                        startActivity(intent)
                        launched = true
                    } catch (_: Exception) {
                        try {
                            startActivity(
                                Intent(
                                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    android.net.Uri.parse("package:$packageName"),
                                ),
                            )
                            launched = true
                        } catch (_: Exception) {
                        }
                    }
                    result.success(mapOf("success" to launched))
                }
                "system/notification_request" -> {
                    if (notificationsGranted()) {
                        result.success(mapOf("success" to true, "granted" to true))
                    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        pendingNotifResult?.let {
                            try { it.success(mapOf("success" to false)) } catch (_: Exception) {}
                        }
                        pendingNotifResult = result
                        androidx.core.app.ActivityCompat.requestPermissions(
                            this,
                            arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                            REQ_POST_NOTIFICATIONS,
                        )
                    } else {
                        result.success(mapOf("success" to true, "granted" to true))
                    }
                }
                "engine/update_check" -> {
                    scope.launch(Dispatchers.IO) {
                        try {
                            val python = py ?: return@launch
                            val engine = python.getModule("grablytic_engine")
                            val updateResult = engine.callAttr("update_check")
                            val jsonStr = pyJson(updateResult)
                            withContext(Dispatchers.Main) { result.success(jsonStr) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) { result.error("ERROR_UPDATE_FAILED", e.message, null) }
                        }
                    }
                }
                "engine/set_update_channel" -> {
                    val channel = call.argument<String>("channel")
                    scope.launch(Dispatchers.IO) {
                        try {
                            val python = py ?: return@launch
                            val engine = python.getModule("grablytic_engine")
                            val channelResult = engine.callAttr("set_update_channel", channel)
                            val jsonStr = pyJson(channelResult)
                            withContext(Dispatchers.Main) { result.success(jsonStr) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) { result.error("ERROR_CHANNEL_FAILED", e.message, null) }
                        }
                    }
                }
                "log/export_to_downloads" -> {
                    val sourcePath = call.argument<String>("source_path")
                    val displayName = call.argument<String>("display_name")
                    scope.launch(Dispatchers.IO) {
                        try {
                            if (sourcePath.isNullOrEmpty() || displayName.isNullOrEmpty()) {
                                throw IllegalArgumentException("missing args")
                            }
                            val dest = exportFileToDownloads(File(sourcePath), displayName)
                            withContext(Dispatchers.Main) {
                                result.success(mapOf("success" to true, "path" to dest))
                            }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) {
                                result.success(mapOf("success" to false, "error" to (e.message ?: "export failed")))
                            }
                        }
                    }
                }
                "schedule/sync" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val intervalMinutes = (call.argument<Int>("interval_minutes") ?: 60).toLong().coerceAtLeast(15L)
                    val wifiOnly = call.argument<Boolean>("wifi_only") ?: true
                    val requiresCharging = call.argument<Boolean>("requires_charging") ?: false

                    ObservedSourcesPollWorker.schedule(
                        context = applicationContext,
                        enabled = enabled,
                        intervalMinutes = intervalMinutes,
                        wifiOnly = wifiOnly,
                        requiresCharging = requiresCharging,
                    )
                    result.success(mapOf("success" to true))
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, PROGRESS_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                private var events: EventChannel.EventSink? = null

                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    this.events = events
                    eventSink = events
                    events?.let { flushTerminals(it) }
                }

                override fun onCancel(arguments: Any?) {
                    if (eventSink === events) {
                        eventSink = null
                    }
                    this.events = null
                }
            }
        )
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    /**
     * Copies an app-private file (log) to the public Download folder so the
     * user can reach it with any file manager — app-private dirs are not
     * browsable on Android 12+. API 29+: MediaStore (no permission needed
     * for our own entries). API 24-28: legacy public path (covered by the
     * manifest's maxSdkVersion-29 WRITE_EXTERNAL_STORAGE). Files capped at
     * 5 MB to keep the copy instant.
     */
    private fun exportFileToDownloads(src: File, displayName: String): String {
        if (!src.isFile) throw IllegalArgumentException("log file missing")
        if (src.length() > 5 * 1024 * 1024) throw IllegalArgumentException("log too large")
        val safeName = displayName.replace(Regex("[^A-Za-z0-9._-]"), "_")
        if (android.os.Build.VERSION.SDK_INT >= 29) {
            val values = android.content.ContentValues().apply {
                put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, safeName)
                put(android.provider.MediaStore.MediaColumns.MIME_TYPE, "text/plain")
                put(
                    android.provider.MediaStore.MediaColumns.RELATIVE_PATH,
                    android.os.Environment.DIRECTORY_DOWNLOADS + "/Grablytic-logs",
                )
                put(android.provider.MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(
                android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, values,
            ) ?: throw java.io.IOException("MediaStore insert failed")
            try {
                contentResolver.openOutputStream(uri)?.use { out ->
                    src.inputStream().use { it.copyTo(out) }
                } ?: throw java.io.IOException("MediaStore open failed")
            } catch (e: Exception) {
                try { contentResolver.delete(uri, null, null) } catch (_: Exception) {}
                throw e
            }
            val done = android.content.ContentValues().apply {
                put(android.provider.MediaStore.MediaColumns.IS_PENDING, 0)
            }
            contentResolver.update(uri, done, null, null)
            return "Download/Grablytic-logs/$safeName"
        } else {
            @Suppress("DEPRECATION")
            val dir = File(
                android.os.Environment.getExternalStoragePublicDirectory(
                    android.os.Environment.DIRECTORY_DOWNLOADS,
                ),
                "Grablytic-logs",
            )
            dir.mkdirs()
            val dest = File(dir, safeName)
            src.copyTo(dest, overwrite = true)
            return dest.absolutePath
        }
    }
}

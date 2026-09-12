package com.theonly.truestream

import android.content.Intent
import android.os.Bundle
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
    private val ENGINE_CHANNEL = "com.theonly.truestream/engine"
    private val PROGRESS_CHANNEL = "com.theonly.truestream/progress"

    private var eventSink: EventChannel.EventSink? = null
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private var methodChannel: MethodChannel? = null
    private var sharedUrl: String? = null
    private var py: Python? = null
    private val activeCallbacks = java.util.concurrent.ConcurrentHashMap<String, EngineEventListener>()

    private var dataDir: String? = null
    private var ffmpegPath: String? = null
    private var aria2cPath: String? = null

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
                sharedUrl = match.value
                scope.launch(Dispatchers.Main) {
                    methodChannel?.invokeMethod("intent/shared_url", mapOf("url" to sharedUrl))
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleSendText(intent)
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

    private fun setupChannels(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ENGINE_CHANNEL)
        methodChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "intent/get_shared" -> {
                    result.success(mapOf("url" to sharedUrl))
                    sharedUrl = null
                }
                "paths/set" -> {
                    this.dataDir = call.argument<String>("data_dir")
                    val outputDir = call.argument<String>("output_dir")
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
                        try {
                            val python = py ?: return@launch
                            val engine = python.getModule("truestream_engine")
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
                            val engine = python.getModule("truestream_engine")
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
                            val engine = python.getModule("truestream_engine")

                            val eventCallback = object : EngineEventListener {
                                // First-failure diagnostics: every delivery
                                // fault below is silent by design (a logging
                                // path must never break downloads), so the
                                // FIRST one warns loudly — it tells the next
                                // diagnostics bundle exactly which hop died.
                                var noSinkWarned = false
                                var sinkFailedWarned = false
                                override fun onEvent(eventJson: String) {
                                    // Drive the keep-alive service from the same
                                    // event stream (progress + terminal events).
                                    try {
                                        val obj = org.json.JSONObject(eventJson)
                                        if (obj.optString("type") == "event") {
                                            val id = obj.optString("download_id")
                                            if (id.isNotEmpty()) {
                                                when (obj.optString("event")) {
                                                    "downloading" -> {
                                                        val dl = obj.optLong("downloaded_bytes", 0)
                                                        val total = obj.optLong("total_bytes", 0)
                                                        val pct = if (total > 0) {
                                                            ((dl * 100) / total).toInt().coerceIn(0, 99)
                                                        } else -1
                                                        DownloadService.update(
                                                            this@MainActivity, id, pct,
                                                        )
                                                    }
                                                    "postprocessing" -> {
                                                        val stageLabel = obj.optString("stage_label", "Processing...")
                                                        DownloadService.updateStage(
                                                            this@MainActivity, id, stageLabel,
                                                        )
                                                    }
                                                    "finished", "error", "cancelled" -> {
                                                        val cancelled = obj.optString("event") == "cancelled"
                                                        DownloadService.done(
                                                            this@MainActivity, id, cancelled,
                                                        )
                                                        activeCallbacks.remove(id)
                                                    }
                                                }
                                            }
                                        }
                                    } catch (_: Exception) {
                                    }
                                    scope.launch(Dispatchers.Main) {
                                        val sink = eventSink
                                        if (sink == null) {
                                            if (!noSinkWarned) {
                                                noSinkWarned = true
                                                android.util.Log.w(
                                                    "TrueStreamEngine",
                                                    "EventChannel sink null — Flutter is not listening; " +
                                                        "progress UI will stall while the download continues",
                                                )
                                            }
                                            return@launch
                                        }
                                        try {
                                            sink.success(eventJson)
                                        } catch (e: Exception) {
                                            if (!sinkFailedWarned) {
                                                sinkFailedWarned = true
                                                android.util.Log.w(
                                                    "TrueStreamEngine",
                                                    "EventChannel sink failed: ${e.message}",
                                                )
                                            }
                                        }
                                    }
                                }
                            }

                            if (downloadId != null) {
                                activeCallbacks[downloadId] = eventCallback
                            }

                            // Keep-alive: user gesture (foreground) → dataSync FGS.
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
                                )
                            } catch (_: Exception) {
                            }

                            val startResult = engine.callAttr("start_download", url, downloadId, configJson(config), networkType, eventCallback)
                            val jsonStr = pyJson(startResult)
                            withContext(Dispatchers.Main) { result.success(jsonStr) }
                        } catch (e: Exception) {
                            if (downloadId != null) {
                                activeCallbacks.remove(downloadId)
                            }
                            withContext(Dispatchers.Main) { result.error("ERROR_START_FAILED", e.message, null) }
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
                            val engine = python.getModule("truestream_engine")
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
                            val engine = python.getModule("truestream_engine")
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
                            val engine = python.getModule("truestream_engine")
                            val playlistResult = engine.callAttr("get_playlist_info", url, configJson(config))
                            val jsonStr = pyJson(playlistResult)
                            withContext(Dispatchers.Main) { result.success(jsonStr) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) { result.error("ERROR_PLAYLIST_FAILED", e.message, null) }
                        }
                    }
                }
                "resume/scan" -> {
                    val cacheDir = call.argument<String>("cache_dir")
                    scope.launch(Dispatchers.IO) {
                        try {
                            val python = py ?: return@launch
                            val engine = python.getModule("truestream_engine")
                            val resumeResult = engine.callAttr("scan_resume_candidates", cacheDir)
                            val jsonStr = pyJson(resumeResult)
                            withContext(Dispatchers.Main) { result.success(jsonStr) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) { result.error("ERROR_RESUME_FAILED", e.message, null) }
                        }
                    }
                }
                "engine/update_check" -> {
                    scope.launch(Dispatchers.IO) {
                        try {
                            val python = py ?: return@launch
                            val engine = python.getModule("truestream_engine")
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
                            val engine = python.getModule("truestream_engine")
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
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, PROGRESS_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
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
                    android.os.Environment.DIRECTORY_DOWNLOADS + "/TrueStream-logs",
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
            return "Download/TrueStream-logs/$safeName"
        } else {
            @Suppress("DEPRECATION")
            val dir = File(
                android.os.Environment.getExternalStoragePublicDirectory(
                    android.os.Environment.DIRECTORY_DOWNLOADS,
                ),
                "TrueStream-logs",
            )
            dir.mkdirs()
            val dest = File(dir, safeName)
            src.copyTo(dest, overwrite = true)
            return dest.absolutePath
        }
    }
}

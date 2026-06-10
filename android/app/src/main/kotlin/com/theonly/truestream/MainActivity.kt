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

class MainActivity : FlutterActivity() {
    private val ENGINE_CHANNEL = "com.theonly.truestream/engine"
    private val PROGRESS_CHANNEL = "com.theonly.truestream/progress"

    private var eventSink: EventChannel.EventSink? = null
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private var methodChannel: MethodChannel? = null
    private var sharedUrl: String? = null
    private var py: Python? = null

    private fun handleSendText(intent: Intent?) {
        if (intent == null) return
        if (intent.action == Intent.ACTION_SEND && intent.type == "text/plain") {
            intent.getStringExtra(Intent.EXTRA_TEXT)?.let { sharedText ->
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
                    val dataDir = call.argument<String>("data_dir")
                    val outputDir = call.argument<String>("output_dir")
                    val ffmpegPath = call.argument<String>("ffmpeg_path")
                    val cacheDir = call.argument<String>("cache_dir")
                    val cookiesPath = call.argument<String>("cookies_path")
                    val aria2cPath = call.argument<String>("aria2c_path")
                    val poToken = call.argument<String>("po_token")

                    if (ffmpegPath != null) {
                        val file = File(ffmpegPath)
                        if (file.exists()) file.setExecutable(true, false)
                    }
                    if (aria2cPath != null) {
                        val file = File(aria2cPath)
                        if (file.exists()) file.setExecutable(true, false)
                    }

                    scope.launch(Dispatchers.IO) {
                        try {
                            val python = py ?: return@launch
                            val engine = python.getModule("truestream_engine")
                            engine.callAttr("set_paths", dataDir, outputDir, ffmpegPath, cacheDir, cookiesPath, aria2cPath, poToken)
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
                            val startResult = engine.callAttr("start_download", url, downloadId, config, networkType)
                            val jsonStr = pyJson(startResult)
                            startProgressPolling(downloadId!!)
                            withContext(Dispatchers.Main) { result.success(jsonStr) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) { result.error("ERROR_START_FAILED", e.message, null) }
                        }
                    }
                }
                "download/cancel" -> {
                    val downloadId = call.argument<String>("download_id")
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
                            val formatsResult = engine.callAttr("get_formats", url, config)
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
                            val playlistResult = engine.callAttr("get_playlist_info", url, config)
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

    @Suppress("UNCHECKED_CAST")
    private fun startProgressPolling(downloadId: String) {
        scope.launch(Dispatchers.IO) {
            try {
                val python = py ?: return@launch
                val downloader = python.getModule("truestream_engine.downloader")
                val rawDownloadsMap = downloader.get("_active_downloads")?.asMap() as? Map<Any?, Any?>
                val downloadInfo = rawDownloadsMap?.get(downloadId) as? Map<Any?, Any?>
                val progressQueue = downloadInfo?.get("progress_queue") as? PyObject
                val resultQueue = downloadInfo?.get("result_queue") as? PyObject

                if (progressQueue == null || resultQueue == null) return@launch

                var isDone = false
                while (!isDone && coroutineContext.isActive) {
                    if (!(progressQueue.callAttr("empty").toJava(Boolean::class.java) as Boolean)) {
                        try {
                            val item = progressQueue.callAttr("get_nowait")
                            withContext(Dispatchers.Main) { eventSink?.success(item.toString()) }
                        } catch (_: Exception) { }
                    }

                    if (!(resultQueue.callAttr("empty").toJava(Boolean::class.java) as Boolean)) {
                        try {
                            val resultVal = resultQueue.callAttr("get_nowait")
                            val resultMap = resultVal.asMap()
                            val isSuccess = try {
                                val raw = resultMap["success"]
                                if (raw is PyObject) raw.toJava(Boolean::class.java) as Boolean else false
                            } catch (_: Exception) { false }
                            val eventJson = if (isSuccess) {
                                "{\"type\":\"event\",\"event\":\"finished\",\"download_id\":\"$downloadId\"}"
                            } else {
                                val errType = try {
                                    val raw = resultMap["error_type"]
                                    if (raw is PyObject) raw.toString() else "ERROR_UNKNOWN"
                                } catch (_: Exception) { "ERROR_UNKNOWN" }
                                val errMsg = try {
                                    val raw = resultMap["error_message"]
                                    if (raw is PyObject) raw.toString() else "Unknown error"
                                } catch (_: Exception) { "Unknown error" }
                                "{\"type\":\"event\",\"event\":\"error\",\"download_id\":\"$downloadId\",\"error_type\":\"$errType\",\"error_message\":\"$errMsg\",\"recoverable\":true}"
                            }
                            withContext(Dispatchers.Main) { eventSink?.success(eventJson) }
                            isDone = true
                        } catch (_: Exception) { }
                    }

                    if (!isDone) delay(100)
                }
            } catch (_: Exception) { }
        }
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}

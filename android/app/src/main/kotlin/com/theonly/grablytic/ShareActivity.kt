package com.theonly.grablytic

import android.content.Intent
import android.os.Bundle
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.embedding.android.FlutterActivityLaunchConfigs

class ShareActivity : MainActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Chaquopy Invariant (§0.7): Ensure Python is started on every Activity entry path
        if (!Python.isStarted()) {
            Python.start(AndroidPlatform(applicationContext))
        }
    }

    override fun getDartEntrypointFunctionName(): String = "shareMain"

    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode =
        FlutterActivityLaunchConfigs.BackgroundMode.transparent

    /**
     * The shared text, capped.
     *
     * `EXTRA_TEXT` is attacker-controlled: any app can send this intent
     * with an arbitrarily large string. The value is handed to the Dart
     * entrypoint, so an oversized payload became a multi-megabyte
     * message into the engine startup (a slow start, an OOM on a
     * low-memory device, or a hang). A shared media URL is a few hundred
     * bytes; 32 KiB is a very generous ceiling.
     */
    override fun getDartEntrypointArgs(): List<String> {
        val text = intent?.getStringExtra(Intent.EXTRA_TEXT) ?: ""
        if (text.isBlank()) return emptyList()
        val capped = if (text.length > MAX_SHARED_TEXT_CHARS) {
            text.substring(0, MAX_SHARED_TEXT_CHARS)
        } else {
            text
        }
        return listOf(capped)
    }

    companion object {
        /** Hard ceiling on the shared text handed to the Dart entrypoint. */
        private const val MAX_SHARED_TEXT_CHARS = 32 * 1024
    }
}

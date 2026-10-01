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

    override fun getDartEntrypointArgs(): List<String> {
        val text = intent?.getStringExtra(Intent.EXTRA_TEXT) ?: ""
        return if (text.isNotBlank()) listOf(text) else emptyList()
    }
}

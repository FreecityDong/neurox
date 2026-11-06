package com.neurox.neurox

import android.content.Intent
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var eeg: EegBleBridge? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        eeg = EegBleBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        val preferences = getSharedPreferences("neurox.preferences", MODE_PRIVATE)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "neurox/preferences").setMethodCallHandler { call, result ->
            when (call.method) {
                "getLanguage" -> result.success(preferences.getString("language", "zh"))
                "setLanguage" -> {
                    val language = call.argument<String>("language")
                    if (language != "zh" && language != "en") result.error("language", "Unsupported language", null)
                    else if (preferences.edit().putString("language", language).commit()) result.success(null)
                    else result.error("language", "Unable to save language", null)
                }
                else -> result.notImplemented()
            }
        }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        eeg?.onPermissionsResult(requestCode)
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        eeg?.onActivityResult(requestCode, resultCode, data)
    }
    override fun onStop() { eeg?.onBackground(); super.onStop() }
    override fun onDestroy() { eeg?.dispose(); eeg = null; super.onDestroy() }
}

package com.tableside.tableside_pos

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tableside/android_hub_service",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    VenueHubForegroundService.start(this, runtimeReady = true)
                    result.success(null)
                }
                "stop" -> {
                    VenueHubForegroundService.stop(this)
                    result.success(null)
                }
                "isRunning" -> result.success(VenueHubForegroundService.isRunning)
                "openBatterySettings" -> {
                    startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}

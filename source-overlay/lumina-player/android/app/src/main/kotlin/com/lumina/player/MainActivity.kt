package com.lumina.player

import android.content.Context
import android.media.AudioManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // System media volume for the player's swipe gesture (0.0 - 1.0).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lumina/volume")
            .setMethodCallHandler { call, result ->
                val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                when (call.method) {
                    "get" -> {
                        val current = audio.getStreamVolume(AudioManager.STREAM_MUSIC)
                        result.success(if (max > 0) current.toDouble() / max else 0.0)
                    }
                    "set" -> {
                        val value = (call.argument<Double>("value") ?: 0.0).coerceIn(0.0, 1.0)
                        audio.setStreamVolume(
                            AudioManager.STREAM_MUSIC,
                            Math.round(value * max).toInt(),
                            0
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}

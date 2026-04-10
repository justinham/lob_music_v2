package com.justinh.lob.lob_music

import android.content.ContentResolver
import android.content.ContentUris
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity: FlutterActivity() {
    private val CHANNEL = "lob_music/delete"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "deleteSong" -> {
                    val id = call.argument<Int>("id")
                    val path = call.argument<String>("path")
                    if (id == null) {
                        result.error("INVALID", "id is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        // Delete from MediaStore by ID
                        val uri = ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id.toLong())
                        contentResolver.delete(uri, null, null)
                        // Also delete the actual file if path is provided
                        if (path != null) {
                            val file = File(path)
                            if (file.exists()) file.delete()
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}

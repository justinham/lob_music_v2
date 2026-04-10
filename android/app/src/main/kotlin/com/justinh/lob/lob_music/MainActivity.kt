package com.justinh.lob.lob_music

import android.content.ContentUris
import android.database.Cursor
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
                    if (id == null) {
                        result.error("INVALID", "id is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val uri = ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id.toLong())

                        // Look up the actual file path from MediaStore
                        var filePath: String? = null
                        val cursor: Cursor? = contentResolver.query(
                            uri,
                            arrayOf(MediaStore.Audio.Media.DATA),
                            null, null, null
                        )
                        if (cursor != null && cursor.moveToFirst()) {
                            val pathIndex = cursor.getColumnIndex(MediaStore.Audio.Media.DATA)
                            if (pathIndex >= 0) filePath = cursor.getString(pathIndex)
                            cursor.close()
                        }

                        // Delete from MediaStore
                        val rows = contentResolver.delete(uri, null, null)

                        // Also delete the actual file
                        if (filePath != null) {
                            val file = File(filePath)
                            if (file.exists()) file.delete()
                        }

                        result.success(rows > 0)
                    } catch (e: Exception) {
                        result.error("ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}

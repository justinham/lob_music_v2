package com.justinh.lob.lob_music

import android.app.Activity
import android.content.IntentSender
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.ContentUris

class MainActivity: FlutterActivity() {
    private val CHANNEL = "lob_music/delete"
    private var pendingResult: io.flutter.plugin.common.MethodChannel.Result? = null

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

                        // Use createDeleteRequest on Android 11+ to get user consent for deletion
                        val pendingIntent = MediaStore.createDeleteRequest(contentResolver, listOf(uri))
                        pendingResult = result
                        startIntentSenderForResult(
                            pendingIntent.intentSender,
                            1001,  // request code
                            null,
                            0, 0, 0
                        )
                    } catch (e: IntentSender.SendIntentException) {
                        result.error("ERROR", "Could not request deletion: ${e.message}", null)
                    } catch (e: Exception) {
                        result.error("ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 1001) {
            pendingResult?.let { result ->
                if (resultCode == Activity.RESULT_OK) {
                    result.success(true)
                } else {
                    result.success(false)
                }
                pendingResult = null
            }
        }
    }
}

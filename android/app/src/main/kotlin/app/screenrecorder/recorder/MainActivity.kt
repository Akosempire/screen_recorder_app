package app.screenrecorder.recorder

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Size
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * Bridge between the Flutter UI and Android: screen recording (RecorderService),
 * the recordings in Movies/Screen Recorder, sharing, and opening links.
 * Channel: "screen_recorder_app/android".
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "screen_recorder_app/android"
        private const val REQ_CAPTURE = 7001
        private const val REQ_PERMISSIONS = 7002
        private const val REQ_DELETE = 7003
    }

    private lateinit var channel: MethodChannel
    private var pendingStart: MethodChannel.Result? = null
    private var pendingMic = false
    private var pendingMaxSeconds = 0
    private var pendingDelete: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(::onCall)
        RecorderBus.listener = { event, data -> channel.invokeMethod(event, data) }
    }

    override fun onDestroy() {
        RecorderBus.listener = null
        super.onDestroy()
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                if (RecorderService.recording) return result.error("busy", "Already recording.", null)
                if (pendingStart != null) return result.error("busy", "Starting already.", null)
                pendingStart = result
                pendingMic = call.argument<Boolean>("mic") ?: false
                pendingMaxSeconds = call.argument<Int>("maxSeconds") ?: 0
                askPermissions()
            }
            "stop" -> { service(RecorderService.ACTION_STOP); result.success(true) }
            "pause" -> { service(RecorderService.ACTION_PAUSE); result.success(true) }
            "resume" -> { service(RecorderService.ACTION_RESUME); result.success(true) }
            "status" -> result.success(
                mapOf(
                    "recording" to RecorderService.recording,
                    "paused" to RecorderService.paused,
                    "elapsedMs" to RecorderService.elapsedMs(),
                )
            )
            "list" -> result.success(listRecordings())
            "thumbnail" -> {
                val uri = Uri.parse(call.argument<String>("uri") ?: "")
                Thread {
                    val bytes = try {
                        val bmp = contentResolver.loadThumbnail(uri, Size(480, 270), null)
                        ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.JPEG, 80, it) }.toByteArray()
                    } catch (_: Exception) { null }
                    runOnUiThread { result.success(bytes) }
                }.start()
            }
            "open" -> {
                val uri = Uri.parse(call.argument<String>("uri") ?: "")
                start(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "video/mp4")
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), result)
            }
            "share" -> {
                val uri = Uri.parse(call.argument<String>("uri") ?: "")
                val send = Intent(Intent.ACTION_SEND).setType("video/mp4")
                    .putExtra(Intent.EXTRA_STREAM, uri)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                start(Intent.createChooser(send, "Share recording"), result)
            }
            "delete" -> delete(Uri.parse(call.argument<String>("uri") ?: ""), result)
            "openUrl" -> {
                val url = call.arguments as? String ?: ""
                if (!url.startsWith("https://") && !url.startsWith("http://")) return result.success(false)
                start(Intent(Intent.ACTION_VIEW, Uri.parse(url)), result)
            }
            "filesDir" -> result.success(filesDir.absolutePath)
            else -> result.notImplemented()
        }
    }

    private fun start(intent: Intent, result: MethodChannel.Result) {
        try {
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.success(false)
        }
    }

    private fun service(action: String) {
        startService(Intent(this, RecorderService::class.java).setAction(action))
    }

    // ---- starting a recording: permissions, then the system capture prompt ----

    private fun askPermissions() {
        val wanted = mutableListOf<String>()
        if (pendingMic && checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            wanted += Manifest.permission.RECORD_AUDIO
        }
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            wanted += Manifest.permission.POST_NOTIFICATIONS
        }
        if (wanted.isEmpty()) askCapture() else requestPermissions(wanted.toTypedArray(), REQ_PERMISSIONS)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_PERMISSIONS) return
        val micIndex = permissions.indexOf(Manifest.permission.RECORD_AUDIO)
        if (micIndex >= 0 && grantResults.getOrNull(micIndex) != PackageManager.PERMISSION_GRANTED) {
            // No microphone permission: record without sound rather than not at all.
            pendingMic = false
            RecorderBus.emit("micDenied")
        }
        askCapture()
    }

    private fun askCapture() {
        val mpm = getSystemService(MediaProjectionManager::class.java)
        @Suppress("DEPRECATION")
        startActivityForResult(mpm.createScreenCaptureIntent(), REQ_CAPTURE)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQ_CAPTURE -> {
                val result = pendingStart ?: return
                pendingStart = null
                if (resultCode != Activity.RESULT_OK || data == null) {
                    result.error("denied", "Screen recording wasn't allowed.", null)
                    return
                }
                val intent = Intent(this, RecorderService::class.java)
                    .setAction(RecorderService.ACTION_START)
                    .putExtra(RecorderService.EXTRA_RESULT_CODE, resultCode)
                    .putExtra(RecorderService.EXTRA_DATA, data)
                    .putExtra(RecorderService.EXTRA_MIC, pendingMic)
                    .putExtra(RecorderService.EXTRA_MAX_SECONDS, pendingMaxSeconds)
                startForegroundService(intent)
                result.success(mapOf("mic" to pendingMic))
            }
            REQ_DELETE -> {
                pendingDelete?.success(resultCode == Activity.RESULT_OK)
                pendingDelete = null
            }
        }
    }

    // ---- the recordings in Movies/Screen Recorder ----

    private fun listRecordings(): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        val projection = arrayOf(
            MediaStore.Video.Media._ID,
            MediaStore.Video.Media.DISPLAY_NAME,
            MediaStore.Video.Media.DURATION,
            MediaStore.Video.Media.SIZE,
            MediaStore.Video.Media.DATE_ADDED,
        )
        val selection = "${MediaStore.Video.Media.RELATIVE_PATH} LIKE ?"
        val args = arrayOf("Movies/Screen Recorder%")
        contentResolver.query(
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI, projection, selection, args,
            "${MediaStore.Video.Media.DATE_ADDED} DESC"
        )?.use { c ->
            val id = c.getColumnIndexOrThrow(MediaStore.Video.Media._ID)
            val name = c.getColumnIndexOrThrow(MediaStore.Video.Media.DISPLAY_NAME)
            val duration = c.getColumnIndexOrThrow(MediaStore.Video.Media.DURATION)
            val size = c.getColumnIndexOrThrow(MediaStore.Video.Media.SIZE)
            val added = c.getColumnIndexOrThrow(MediaStore.Video.Media.DATE_ADDED)
            while (c.moveToNext() && out.size < 200) {
                val uri = ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, c.getLong(id))
                out += mapOf(
                    "uri" to uri.toString(),
                    "name" to c.getString(name),
                    "durationMs" to c.getLong(duration),
                    "size" to c.getLong(size),
                    "added" to c.getLong(added) * 1000,
                )
            }
        }
        return out
    }

    private fun delete(uri: Uri, result: MethodChannel.Result) {
        try {
            result.success(contentResolver.delete(uri, null, null) > 0)
        } catch (e: SecurityException) {
            // Recordings from before a reinstall belong to the old install:
            // Android asks the user to confirm.
            if (Build.VERSION.SDK_INT >= 30) {
                pendingDelete = result
                val request = MediaStore.createDeleteRequest(contentResolver, listOf(uri))
                @Suppress("DEPRECATION")
                startIntentSenderForResult(request.intentSender, REQ_DELETE, null, 0, 0, 0)
            } else {
                result.success(false)
            }
        }
    }
}

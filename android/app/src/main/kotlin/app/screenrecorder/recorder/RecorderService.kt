package app.screenrecorder.recorder

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.provider.MediaStore
import android.util.DisplayMetrics
import android.view.WindowManager
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.max
import kotlin.math.roundToInt

/** Events from the recorder to the Flutter side (set by MainActivity). */
object RecorderBus {
    var listener: ((event: String, data: Map<String, Any?>) -> Unit)? = null

    fun emit(event: String, data: Map<String, Any?> = emptyMap()) {
        Handler(Looper.getMainLooper()).post { listener?.invoke(event, data) }
    }
}

/**
 * Records the screen (and optionally the microphone) with MediaProjection +
 * MediaRecorder in a foreground service, so recording continues while the
 * user works in other apps. Saves the result to Movies/Screen Recorder.
 */
class RecorderService : Service() {

    companion object {
        const val ACTION_START = "start"
        const val ACTION_STOP = "stop"
        const val ACTION_PAUSE = "pause"
        const val ACTION_RESUME = "resume"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_DATA = "data"
        const val EXTRA_MIC = "mic"
        const val EXTRA_MAX_SECONDS = "maxSeconds"

        private const val CHANNEL_ID = "recording"
        private const val CHANNEL_DONE = "saved"
        private const val NOTIFICATION_ID = 41
        private const val NOTIFICATION_DONE = 42

        /** Current state, read by MainActivity for `status`. */
        @Volatile var recording = false
        @Volatile var paused = false
        @Volatile var startedAt = 0L
        @Volatile var pausedTotal = 0L
        @Volatile var pausedAt = 0L

        fun elapsedMs(): Long {
            if (!recording) return 0
            val now = if (paused) pausedAt else SystemClock.elapsedRealtime()
            return max(0, now - startedAt - pausedTotal)
        }
    }

    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var recorder: MediaRecorder? = null
    private var tempFile: File? = null
    private var hitLimit = false
    private var finishing = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> start(intent)
            ACTION_STOP -> finish()
            ACTION_PAUSE -> pause()
            ACTION_RESUME -> resume()
        }
        return START_NOT_STICKY
    }

    private fun start(intent: Intent) {
        if (recording) return
        val mic = intent.getBooleanExtra(EXTRA_MIC, false)
        val maxSeconds = intent.getIntExtra(EXTRA_MAX_SECONDS, 0)
        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
        val data: Intent? = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(EXTRA_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION") intent.getParcelableExtra(EXTRA_DATA)
        }
        if (data == null) {
            fail("Screen capture permission was not given.")
            return
        }

        createChannels()
        // Must be in the foreground before asking for the projection (Android 14+).
        // The microphone service type exists from Android 11; Android 10
        // allows the microphone under the media projection type.
        val type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION or
            (if (mic && Build.VERSION.SDK_INT >= 30) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0)
        try {
            startForeground(NOTIFICATION_ID, recordingNotification(false), type)
        } catch (e: Exception) {
            fail("Android didn't allow recording to start: ${e.message}")
            return
        }

        try {
            val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val p = mpm.getMediaProjection(resultCode, data)
                ?: return fail("Screen capture permission was not given.")
            projection = p
            p.registerCallback(object : MediaProjection.Callback() {
                // The user stopped sharing from the system (status bar chip / lock screen).
                override fun onStop() { finish() }
            }, Handler(Looper.getMainLooper()))

            val (width, height, dpi) = captureSize()
            val file = File(getExternalFilesDir(null) ?: filesDir, "recording-${System.currentTimeMillis()}.mp4")
            tempFile = file

            val r = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(this) else @Suppress("DEPRECATION") MediaRecorder()
            if (mic) r.setAudioSource(MediaRecorder.AudioSource.MIC)
            r.setVideoSource(MediaRecorder.VideoSource.SURFACE)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setOutputFile(file.absolutePath)
            r.setVideoEncoder(MediaRecorder.VideoEncoder.H264)
            r.setVideoSize(width, height)
            r.setVideoFrameRate(30)
            r.setVideoEncodingBitRate(max(2_000_000, (width * height * 4.5).roundToInt()))
            if (mic) {
                r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                r.setAudioEncodingBitRate(128_000)
                r.setAudioSamplingRate(44_100)
            }
            if (maxSeconds > 0) r.setMaxDuration(maxSeconds * 1000)
            r.setOnInfoListener { _, what, _ ->
                if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED) {
                    hitLimit = true
                    finish()
                }
            }
            r.prepare()
            recorder = r
            display = p.createVirtualDisplay(
                "ScreenRecorder", width, height, dpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, r.surface, null, null
            )
            r.start()
            recording = true
            paused = false
            startedAt = SystemClock.elapsedRealtime()
            pausedTotal = 0
            RecorderBus.emit("started", mapOf("width" to width, "height" to height))
            notifyRecording()
        } catch (e: Exception) {
            fail("Could not start recording: ${e.message}")
        }
    }

    /** Screen size scaled to at most 1920 px on the long side, even numbers. */
    private fun captureSize(): Triple<Int, Int, Int> {
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val w: Int
        val h: Int
        val dpi = resources.displayMetrics.densityDpi
        if (Build.VERSION.SDK_INT >= 30) {
            val b = wm.maximumWindowMetrics.bounds
            w = b.width(); h = b.height()
        } else {
            val m = DisplayMetrics()
            @Suppress("DEPRECATION") wm.defaultDisplay.getRealMetrics(m)
            w = m.widthPixels; h = m.heightPixels
        }
        val scale = minOf(1.0, 1920.0 / max(w, h))
        fun even(v: Double) = (v.roundToInt() / 2) * 2
        return Triple(even(w * scale), even(h * scale), dpi)
    }

    private fun pause() {
        if (!recording || paused) return
        try {
            recorder?.pause()
            paused = true
            pausedAt = SystemClock.elapsedRealtime()
            RecorderBus.emit("paused")
            notifyRecording()
        } catch (_: Exception) {}
    }

    private fun resume() {
        if (!recording || !paused) return
        try {
            recorder?.resume()
            pausedTotal += SystemClock.elapsedRealtime() - pausedAt
            paused = false
            RecorderBus.emit("resumed")
            notifyRecording()
        } catch (_: Exception) {}
    }

    private fun finish() {
        if (finishing) return
        finishing = true
        val duration = elapsedMs()
        var ok = true
        try { recorder?.stop() } catch (_: Exception) { ok = false } // too short: no valid file
        try { recorder?.release() } catch (_: Exception) {}
        recorder = null
        try { display?.release() } catch (_: Exception) {}
        display = null
        try { projection?.stop() } catch (_: Exception) {}
        projection = null
        recording = false
        paused = false

        val file = tempFile
        tempFile = null
        var uri: Uri? = null
        if (ok && file != null && file.length() > 0) {
            uri = saveToGallery(file)
        }
        file?.delete()
        if (Build.VERSION.SDK_INT >= 33) stopForeground(STOP_FOREGROUND_REMOVE)
        else @Suppress("DEPRECATION") stopForeground(true)

        if (uri != null) {
            showSaved(uri)
            RecorderBus.emit("finished", mapOf("uri" to uri.toString(), "durationMs" to duration, "limit" to hitLimit))
        } else {
            RecorderBus.emit("error", mapOf("message" to "The recording was too short or could not be saved."))
        }
        hitLimit = false
        finishing = false
        stopSelf()
    }

    private fun saveToGallery(file: File): Uri? {
        val name = "Screen Recording " + SimpleDateFormat("yyyy-MM-dd HH-mm-ss", Locale.US).format(Date()) + ".mp4"
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, name)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, "Movies/Screen Recorder")
            put(MediaStore.Video.Media.IS_PENDING, 1)
        }
        val resolver = contentResolver
        val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values) ?: return null
        return try {
            resolver.openOutputStream(uri)?.use { out -> file.inputStream().use { it.copyTo(out) } }
            values.clear()
            values.put(MediaStore.Video.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            uri
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            null
        }
    }

    private fun fail(message: String) {
        recording = false
        RecorderBus.emit("error", mapOf("message" to message))
        try {
            if (Build.VERSION.SDK_INT >= 33) stopForeground(STOP_FOREGROUND_REMOVE)
            else @Suppress("DEPRECATION") stopForeground(true)
        } catch (_: Exception) {}
        stopSelf()
    }

    // ---- notifications -----------------------------------------------------

    private fun createChannels() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Recording", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while Screen Recorder is recording"
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_DONE, "Saved recordings", NotificationManager.IMPORTANCE_DEFAULT)
        )
    }

    private fun action(action: String): PendingIntent = PendingIntent.getService(
        this, action.hashCode(),
        Intent(this, RecorderService::class.java).setAction(action),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
    )

    private fun openApp(): PendingIntent = PendingIntent.getActivity(
        this, 0,
        Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
    )

    private fun recordingNotification(isPaused: Boolean): Notification {
        val b = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setContentTitle(if (isPaused) "Recording paused" else "Recording your screen")
            .setContentText("Tap Stop to save it to your Gallery")
            .setOngoing(true)
            .setContentIntent(openApp())
        if (!isPaused && recording) {
            b.setUsesChronometer(true)
            b.setWhen(System.currentTimeMillis() - elapsedMs())
        }
        b.addAction(
            Notification.Action.Builder(null, if (isPaused) "Resume" else "Pause",
                action(if (isPaused) ACTION_RESUME else ACTION_PAUSE)).build()
        )
        b.addAction(Notification.Action.Builder(null, "Stop", action(ACTION_STOP)).build())
        return b.build()
    }

    private fun notifyRecording() {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, recordingNotification(paused))
    }

    private fun showSaved(uri: Uri) {
        val view = PendingIntent.getActivity(
            this, 1,
            Intent(Intent.ACTION_VIEW).setDataAndType(uri, "video/mp4")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE
        )
        val n = Notification.Builder(this, CHANNEL_DONE)
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setContentTitle(if (hitLimit) "Recording saved (free time limit reached)" else "Recording saved")
            .setContentText("Movies › Screen Recorder. Tap to watch.")
            .setContentIntent(view)
            .setAutoCancel(true)
            .build()
        try {
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION_DONE, n)
        } catch (_: SecurityException) {}
    }
}

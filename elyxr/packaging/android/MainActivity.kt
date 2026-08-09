package com.elyxr.elyxr

import android.content.pm.PackageManager
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer

// The Flutter entry point plus the bridge Dart uses to run the on-device lymnal.
// Android can't shell out from Dart, so the app asks the native side to start the
// foreground service that execs lymnal on loopback (127.0.0.1:7749) — the same
// client -> local-lymnal -> trove model as desktop.
class MainActivity : FlutterActivity() {
    private val channel = "elyxr/lymnal"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Edge-to-edge: lay the window's content out behind the system bars, all
        // the way to the screen's physical edges (pixel 0 at the top), instead of
        // fitting it inside the status/nav insets. Pairs with the cutout mode
        // below and the immersive bar-hiding in main.dart.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        // Render UNDER the camera punch-hole, exactly like every other full-screen
        // app on the device. A punch-hole needs no letterbox — the app just draws
        // to the top pixel and the hole floats over its pixels — BUT only if the
        // window declares it handles the cutout. Without this declaration Android
        // pushes our content below the cutout and paints that strip black: the
        // "black bar at the top". ALWAYS = draw into the cutout in every case
        // (SHORT_EDGES on the couple of API 28-29 devices that lack ALWAYS). This
        // is a native window flag; nothing on the Dart/SafeArea side can set it.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                    } else {
                        WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                    }
            }
        }
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // On Android 13+ a foreground service still runs without notification
        // permission, but the ongoing notice is hidden. Ask once so the user can
        // see lymnal is alive.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this, arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1
            )
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Where lymnal's config + link.json + lymbo cache live. Dart
                    // writes link.json here after pairing; the service points
                    // HOME/LYMNAL_CONFIG/XDG_CACHE_HOME at it.
                    "dataDir" -> result.success(filesDir.absolutePath)
                    // Where the bundled native binaries land (liblymnal.so,
                    // libmodrender.so + libopenmpt.so). Dart execs the module
                    // renderer from here with LD_LIBRARY_PATH set to it.
                    "nativeLibDir" -> result.success(applicationInfo.nativeLibraryDir)
                    "start" -> {
                        LymnalService.start(this)
                        result.success(null)
                    }
                    "stop" -> {
                        LymnalService.stop(this)
                        result.success(null)
                    }
                    // Strip an MP4/M4A down to its audio track. These "audio"
                    // files can carry video, which the media backend would render
                    // — the app only ever wants sound. Copy just the audio track
                    // (no re-encode) into a new audio-only file. Off the main
                    // thread; the file can be large.
                    "extractAudio" -> {
                        val inPath = call.argument<String>("in")
                        val outPath = call.argument<String>("out")
                        if (inPath == null || outPath == null) {
                            result.success(false)
                        } else {
                            Thread {
                                val ok = try {
                                    extractAudioTrack(inPath, outPath)
                                } catch (e: Exception) {
                                    false
                                }
                                runOnUiThread { result.success(ok) }
                            }.start()
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // Remux the first audio track of [inPath] into a fresh audio-only MP4/M4A at
    // [outPath] via MediaExtractor + MediaMuxer — a lossless copy of the encoded
    // samples, no decode/re-encode. Returns false if there's no audio track.
    private fun extractAudioTrack(inPath: String, outPath: String): Boolean {
        File(outPath).delete()
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(inPath)
            var audioTrack = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    audioTrack = i
                    format = f
                    break
                }
            }
            val fmt = format ?: return false
            extractor.selectTrack(audioTrack)

            val muxer = MediaMuxer(outPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val outIndex = muxer.addTrack(fmt)
            muxer.start()
            try {
                val cap = if (fmt.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                    maxOf(fmt.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE), 256 * 1024)
                } else {
                    1 * 1024 * 1024
                }
                val buffer = ByteBuffer.allocate(cap)
                val info = MediaCodec.BufferInfo()
                while (true) {
                    val size = extractor.readSampleData(buffer, 0)
                    if (size < 0) break
                    info.offset = 0
                    info.size = size
                    info.presentationTimeUs = extractor.sampleTime
                    info.flags =
                        if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) {
                            MediaCodec.BUFFER_FLAG_KEY_FRAME
                        } else {
                            0
                        }
                    muxer.writeSampleData(outIndex, buffer, info)
                    extractor.advance()
                }
            } finally {
                muxer.stop()
                muxer.release()
            }
            return File(outPath).length() > 0
        } finally {
            extractor.release()
        }
    }
}

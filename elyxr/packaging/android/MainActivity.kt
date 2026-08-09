package com.elyxr.elyxr

import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
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
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

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
                    // Decode a compressed audio file (m4a/aac/mp3/…) to a 16-bit
                    // PCM WAV. The phone has no ffmpeg, so this is how the app gets
                    // real samples: the WAV plays as pure audio (no video track to
                    // render) AND is what the visualizer's FFT reads off the play
                    // head, so the lightshow works on Android too. Off the main
                    // thread — decoding a whole track takes a moment.
                    "decodeToWav" -> {
                        val inPath = call.argument<String>("in")
                        val outPath = call.argument<String>("out")
                        if (inPath == null || outPath == null) {
                            result.success(false)
                        } else {
                            Thread {
                                val ok = try {
                                    decodeToWav(inPath, outPath)
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

    // Decode the first audio track of [inPath] to a 16-bit little-endian PCM WAV
    // at [outPath] using MediaExtractor + MediaCodec. Streams decoded chunks
    // straight to disk (never holds the whole song in memory) and back-patches
    // the 44-byte header once the true sample-rate/channels and length are known.
    // Returns false if there's no audio track or nothing decoded.
    private fun decodeToWav(inPath: String, outPath: String): Boolean {
        File(outPath).delete()
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        var raf: RandomAccessFile? = null
        try {
            extractor.setDataSource(inPath)
            var trackIndex = -1
            var trackFormat: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    trackIndex = i
                    trackFormat = f
                    break
                }
            }
            val fmt = trackFormat ?: return false
            val mime = fmt.getString(MediaFormat.KEY_MIME) ?: return false
            extractor.selectTrack(trackIndex)

            // Sample rate / channels from the input format; corrected below if the
            // decoder reports different values once it starts producing output.
            var sampleRate = if (fmt.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            } else {
                44100
            }
            var channels = if (fmt.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            } else {
                2
            }

            // Ask the decoder for 16-bit PCM specifically — our WAV header
            // declares 16-bit, so a device that defaulted to float output would
            // otherwise play back as noise. Supported API 24+.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                fmt.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            }

            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(fmt, null, null, 0)
            codec.start()

            raf = RandomAccessFile(outPath, "rw")
            raf.setLength(0)
            raf.write(ByteArray(44)) // reserve the header; back-patched at the end
            var dataBytes = 0L

            val info = MediaCodec.BufferInfo()
            val timeoutUs = 10_000L
            var sawInputEOS = false
            var sawOutputEOS = false
            while (!sawOutputEOS) {
                if (!sawInputEOS) {
                    val inIndex = codec.dequeueInputBuffer(timeoutUs)
                    if (inIndex >= 0) {
                        val inBuf = codec.getInputBuffer(inIndex)!!
                        val size = extractor.readSampleData(inBuf, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(
                                inIndex, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            sawInputEOS = true
                        } else {
                            codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIndex = codec.dequeueOutputBuffer(info, timeoutUs)
                if (outIndex >= 0) {
                    if (info.size > 0) {
                        val outBuf = codec.getOutputBuffer(outIndex)!!
                        val chunk = ByteArray(info.size)
                        outBuf.position(info.offset)
                        outBuf.get(chunk, 0, info.size)
                        raf.write(chunk)
                        dataBytes += info.size
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        sawOutputEOS = true
                    }
                } else if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val out = codec.outputFormat
                    if (out.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                        sampleRate = out.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    }
                    if (out.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                        channels = out.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    }
                }
            }

            writeWavHeader(raf, dataBytes, sampleRate, channels)
            return dataBytes > 0
        } finally {
            try { raf?.close() } catch (e: Exception) {}
            try { codec?.stop() } catch (e: Exception) {}
            try { codec?.release() } catch (e: Exception) {}
            extractor.release()
        }
    }

    // Seek to the front and write a standard 44-byte 16-bit PCM WAV header for a
    // body of [dataLen] bytes. Little-endian, as the format requires.
    private fun writeWavHeader(
        raf: RandomAccessFile, dataLen: Long, sampleRate: Int, channels: Int
    ) {
        val byteRate = sampleRate * channels * 2
        val blockAlign = channels * 2
        val bb = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        bb.put("RIFF".toByteArray(Charsets.US_ASCII))
        bb.putInt((36 + dataLen).toInt())
        bb.put("WAVE".toByteArray(Charsets.US_ASCII))
        bb.put("fmt ".toByteArray(Charsets.US_ASCII))
        bb.putInt(16)                       // PCM fmt chunk size
        bb.putShort(1.toShort())            // audio format 1 = PCM
        bb.putShort(channels.toShort())
        bb.putInt(sampleRate)
        bb.putInt(byteRate)
        bb.putShort(blockAlign.toShort())
        bb.putShort(16.toShort())           // bits per sample
        bb.put("data".toByteArray(Charsets.US_ASCII))
        bb.putInt(dataLen.toInt())
        raf.seek(0)
        raf.write(bb.array())
    }
}

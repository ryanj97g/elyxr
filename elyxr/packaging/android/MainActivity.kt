package com.elyxr.elyxr

import android.content.pm.PackageManager
import android.os.Build
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// The Flutter entry point plus the bridge Dart uses to run the on-device lymnal.
// Android can't shell out from Dart, so the app asks the native side to start the
// foreground service that execs lymnal on loopback (127.0.0.1:7749) — the same
// client -> local-lymnal -> trove model as desktop.
class MainActivity : FlutterActivity() {
    private val channel = "elyxr/lymnal"

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
                    "start" -> {
                        LymnalService.start(this)
                        result.success(null)
                    }
                    "stop" -> {
                        LymnalService.stop(this)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}

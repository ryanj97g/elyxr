package com.elyxr.elyxr

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import java.io.File

// Runs the bundled lymnal daemon as a foreground service, so the phone keeps its
// OWN local proxy (127.0.0.1:7749) with lymbo alive even while the app is
// backgrounded — the identical client -> local-lymnal -> trove model as desktop,
// not a special direct-to-server mode.
//
// The daemon ships as liblymnal.so (Android lets an app execute a binary from its
// native-lib dir). It only runs once the device is paired (link.json present); an
// unpaired phone pairs with the remote directly and starts this afterward.
class LymnalService : Service() {
    private var process: Process? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIF_ID, buildNotification())
        if (process == null || process?.isAlive != true) startLymnal()
        return START_STICKY
    }

    private fun startLymnal() {
        val configDir = File(filesDir, "lymnal").apply { mkdirs() }
        // No pairing yet — nothing to proxy. Stay a bare foreground service; the
        // app restarts us once it has written link.json.
        if (!File(configDir, "link.json").exists()) return
        val bin = File(applicationInfo.nativeLibraryDir, "liblymnal.so")
        val cacheDir = File(filesDir, "cache").apply { mkdirs() }
        try {
            process = ProcessBuilder(bin.absolutePath)
                .apply {
                    environment()["HOME"] = filesDir.absolutePath
                    environment()["LYMNAL_CONFIG"] = File(configDir, "config.toml").absolutePath
                    environment()["XDG_CACHE_HOME"] = cacheDir.absolutePath
                    redirectErrorStream(true)
                }
                .start()
        } catch (_: Exception) {
            // If it can't start, the app falls back to its normal offline state.
        }
    }

    override fun onDestroy() {
        process?.destroy()
        process = null
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        val channelId = "lymnal"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(channelId) == null) {
                mgr.createNotificationChannel(
                    NotificationChannel(channelId, "elyxr", NotificationManager.IMPORTANCE_LOW)
                )
            }
        }
        val builder =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                Notification.Builder(this, channelId)
            else
                @Suppress("DEPRECATION") Notification.Builder(this)
        return builder
            .setContentTitle("elyxr")
            .setContentText("Trove connected")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val NOTIF_ID = 7749

        fun start(context: Context) {
            val i = Intent(context, LymnalService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                context.startForegroundService(i)
            else
                context.startService(i)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, LymnalService::class.java))
        }
    }
}

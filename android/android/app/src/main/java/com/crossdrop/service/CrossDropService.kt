package com.crossdrop.service

import android.app.Service
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.crossdrop.engine.Engine
import com.crossdrop.notifications.Notifier

/**
 * Foreground service that keeps CrossDrop alive only while receiving is
 * switched on or a transfer is running, so a transfer survives the app going
 * to the background. It does no work itself; the [Engine] does.
 */
class CrossDropService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val engine = Engine.get(this)
        // Always satisfy the startForeground contract first, then stop if nothing needs us.
        val (title, text, progress) = engine.serviceStatus()
        val notification = engine.notifier.status(title, text, progress)
        try {
            ServiceCompat.startForeground(
                this, Notifier.STATUS_ID, notification,
                if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0,
            )
            running = this
        } catch (e: Exception) {
            // Starting in the background is not allowed on this OS version; give up quietly.
            stopSelf()
            return START_NOT_STICKY
        }
        if (!engine.needsService()) stopNow()
        return START_NOT_STICKY
    }

    private fun stopNow() {
        running = null
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        if (running === this) running = null
        super.onDestroy()
    }

    companion object {
        @Volatile
        private var running: CrossDropService? = null
        private var lastRefresh = 0L

        /**
         * Starts, refreshes or stops the service to match the engine. [grantUris]
         * are content URIs the service must keep read access to while sending.
         */
        fun update(context: Context, grantUris: List<Uri> = emptyList()) {
            val engine = Engine.get(context)
            val needed = engine.needsService()
            val svc = running
            if (!needed && svc == null) return
            if (!needed && svc != null) {
                svc.stopNow()
                return
            }
            val intent = Intent(context, CrossDropService::class.java)
            if (grantUris.isNotEmpty()) {
                val clip = ClipData.newRawUri("files", grantUris.first())
                grantUris.drop(1).forEach { clip.addItem(ClipData.Item(it)) }
                intent.clipData = clip
                intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            try {
                ContextCompat.startForegroundService(context, intent)
            } catch (e: Exception) {
                // Background start restrictions: the transfer still runs while the app process lives.
            }
        }

        /** Updates the ongoing notification, at most once a second. */
        fun refreshNotification(context: Context) {
            val svc = running ?: return
            val now = SystemClock.elapsedRealtime()
            if (now - lastRefresh < 1000) return
            lastRefresh = now
            val engine = Engine.get(context)
            if (!engine.needsService()) {
                svc.stopNow()
                return
            }
            val (title, text, progress) = engine.serviceStatus()
            if (engine.notifier.canPost()) {
                runCatching {
                    androidx.core.app.NotificationManagerCompat.from(context)
                        .notify(Notifier.STATUS_ID, engine.notifier.status(title, text, progress))
                }
            }
        }
    }
}

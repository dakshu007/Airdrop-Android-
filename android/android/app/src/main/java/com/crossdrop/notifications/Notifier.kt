package com.crossdrop.notifications

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.crossdrop.MainActivity
import com.crossdrop.R

/**
 * Notifications. File names are never shown on the lock screen: every
 * notification is VISIBILITY_PRIVATE with a generic public version.
 */
class Notifier(private val context: Context) {
    private val nm = NotificationManagerCompat.from(context)

    init {
        val sys = context.getSystemService(NotificationManager::class.java)
        sys.createNotificationChannel(
            NotificationChannel(CHANNEL_STATUS, "Receiving and transfers", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while CrossDrop is visible to nearby devices or moving files"
                setShowBadge(false)
            },
        )
        sys.createNotificationChannel(
            NotificationChannel(CHANNEL_REQUESTS, "Incoming requests", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Pairing codes and incoming files that need your approval"
            },
        )
        sys.createNotificationChannel(
            NotificationChannel(CHANNEL_RESULTS, "Finished transfers", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "When files have arrived or a transfer failed"
            },
        )
    }

    fun openAppIntent(): PendingIntent = PendingIntent.getActivity(
        context, 0,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun base(channel: String, title: String, text: String, publicTitle: String) =
        NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(openAppIntent())
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(
                NotificationCompat.Builder(context, channel)
                    .setSmallIcon(R.drawable.ic_notification)
                    .setContentTitle(publicTitle)
                    .build(),
            )

    fun status(title: String, text: String, progress: Int?): android.app.Notification =
        base(CHANNEL_STATUS, title, text, "CrossDrop is active")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .apply { if (progress != null) setProgress(100, progress.coerceIn(0, 100), false) }
            .build()

    fun request(id: String, title: String, text: String) = post(
        id.hashCode(),
        base(CHANNEL_REQUESTS, title, text, "CrossDrop request")
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setTimeoutAfter(120_000)
            .build(),
    )

    fun result(id: String, title: String, text: String) = post(
        id.hashCode(),
        base(CHANNEL_RESULTS, title, text, "CrossDrop transfer finished")
            .setAutoCancel(true)
            .build(),
    )

    fun cancel(id: String) = nm.cancel(id.hashCode())

    fun canPost(): Boolean = nm.areNotificationsEnabled() &&
        (Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)

    private fun post(id: Int, n: android.app.Notification) {
        if (!canPost()) return
        try {
            nm.notify(id, n)
        } catch (e: SecurityException) {
            // Permission revoked between the check and the call.
        }
    }

    companion object {
        const val CHANNEL_STATUS = "status"
        const val CHANNEL_REQUESTS = "requests"
        const val CHANNEL_RESULTS = "results"
        const val STATUS_ID = 1
    }
}

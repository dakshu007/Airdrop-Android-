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

    fun request(id: String, title: String, text: String, actions: List<NotificationCompat.Action> = emptyList()): Boolean = post(
        id.hashCode(),
        base(CHANNEL_REQUESTS, title, text, "CrossDrop request")
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setTimeoutAfter(120_000)
            .apply { actions.forEach(::addAction) }
            .build(),
    )

    fun result(
        id: String,
        title: String,
        text: String,
        actions: List<NotificationCompat.Action> = emptyList(),
        tap: PendingIntent? = null,
    ) = post(
        id.hashCode(),
        base(CHANNEL_RESULTS, title, text, "CrossDrop transfer finished")
            .setAutoCancel(true)
            .apply {
                actions.forEach(::addAction)
                if (tap != null) setContentIntent(tap)
            }
            .build(),
    )

    /**
     * A paired Mac asks for a photo (§9.7). High priority; never names files. Tapping opens
     * CrossDrop on its capture screen; the actions go straight to the camera or the photo picker.
     * Returns true only when the notification was actually posted.
     */
    fun capture(
        id: String,
        title: String,
        text: String,
        tap: PendingIntent,
        actions: List<NotificationCompat.Action>,
        timeoutMs: Long,
    ): Boolean = channelEnabled(CHANNEL_REQUESTS) && post(
        id.hashCode(),
        base(CHANNEL_REQUESTS, title, text, "CrossDrop request")
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(tap)
            .setAutoCancel(true)
            .setTimeoutAfter(timeoutMs)
            .apply { actions.forEach(::addAction) }
            .build(),
    )

    /** "Paste from <Mac>": text that arrived, with Copy, gone after [timeoutMs]. The text itself is not shown. */
    fun clip(id: String, title: String, text: String, copy: NotificationCompat.Action, timeoutMs: Long): Boolean = post(
        id.hashCode(),
        base(CHANNEL_RESULTS, title, text, "CrossDrop received something")
            .setAutoCancel(true)
            .setTimeoutAfter(timeoutMs)
            .addAction(copy)
            .build(),
    )

    /** A suggestion, e.g. "Send this screenshot to …"; quiet and short-lived. */
    fun suggestion(id: String, title: String, text: String, actions: List<NotificationCompat.Action>) = post(
        id.hashCode(),
        base(CHANNEL_RESULTS, title, text, "CrossDrop suggestion")
            .setAutoCancel(true)
            .setTimeoutAfter(60_000)
            .apply { actions.forEach(::addAction) }
            .build(),
    )

    /** An action button handled by [NotificationActionReceiver]. */
    fun action(label: String, action: String, id: String, extra: String? = null): NotificationCompat.Action {
        val intent = Intent(context, NotificationActionReceiver::class.java)
            .setAction(action)
            .putExtra(NotificationActionReceiver.EXTRA_ID, id)
            .apply { if (extra != null) putExtra(NotificationActionReceiver.EXTRA_VALUE, extra) }
        val pi = PendingIntent.getBroadcast(
            context, (action + id).hashCode(), intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Action.Builder(0, label, pi).build()
    }

    /** An action button that opens an activity (a file or a link). */
    fun activityAction(label: String, id: String, intent: Intent): NotificationCompat.Action =
        NotificationCompat.Action.Builder(0, label, activityIntent(id, intent)).build()

    fun activityIntent(id: String, intent: Intent): PendingIntent = PendingIntent.getActivity(
        context, ("open" + id).hashCode(), intent,
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    fun cancel(id: String) = nm.cancel(id.hashCode())

    /** False when the user turned this channel off in system settings. */
    private fun channelEnabled(channel: String): Boolean =
        (nm.getNotificationChannel(channel)?.importance ?: NotificationManager.IMPORTANCE_DEFAULT) != NotificationManager.IMPORTANCE_NONE

    fun canPost(): Boolean = nm.areNotificationsEnabled() &&
        (Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)

    private fun post(id: Int, n: android.app.Notification): Boolean {
        if (!canPost()) return false
        return try {
            nm.notify(id, n)
            true
        } catch (e: SecurityException) {
            // Permission revoked between the check and the call.
            false
        }
    }

    companion object {
        const val CHANNEL_STATUS = "status"
        const val CHANNEL_REQUESTS = "requests"
        const val CHANNEL_RESULTS = "results"
        const val STATUS_ID = 1
    }
}

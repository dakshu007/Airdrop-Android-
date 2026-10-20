package com.crossdrop.engine

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.crossdrop.storage.Prefs

/** Maps the platform state to the NotificationPermission values in types.ts. */
object NotificationPermissions {
    fun status(context: Context, prefs: Prefs): String {
        val enabled = NotificationManagerCompat.from(context).areNotificationsEnabled()
        if (Build.VERSION.SDK_INT < 33) return if (enabled) "notRequired" else "denied"
        val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        return when {
            granted && enabled -> "granted"
            granted -> "denied" // Allowed but switched off in system settings.
            prefs.notificationPermissionAsked -> "denied"
            else -> "undetermined"
        }
    }
}

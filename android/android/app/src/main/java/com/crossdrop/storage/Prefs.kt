package com.crossdrop.storage

import android.content.Context
import android.os.Build
import android.provider.Settings

/** Small local settings. Nothing here leaves the device. */
class Prefs(private val context: Context) {
    private val sp = context.getSharedPreferences("crossdrop_prefs", Context.MODE_PRIVATE)

    var deviceName: String
        get() = sp.getString("deviceName", null)?.takeIf { it.isNotBlank() } ?: defaultName()
        set(value) = sp.edit().putString("deviceName", value.trim().take(64)).apply()

    var notificationPermissionAsked: Boolean
        get() = sp.getBoolean("notificationAsked", false)
        set(value) = sp.edit().putBoolean("notificationAsked", value).apply()

    private fun defaultName(): String =
        Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() }
            ?: Build.MODEL
}

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

    /** Soft sound when a transfer finishes and is verified. */
    var sound: Boolean
        get() = sp.getBoolean("sound", true)
        set(value) = sp.edit().putBoolean("sound", value).apply()

    /** Light haptic ticks for pairing codes and finished transfers. */
    var haptics: Boolean
        get() = sp.getBoolean("haptics", true)
        set(value) = sp.edit().putBoolean("haptics", value).apply()

    /** True once the welcome screen has been dismissed. */
    var welcomed: Boolean
        get() = sp.getBoolean("welcomed", false)
        set(value) = sp.edit().putBoolean("welcomed", value).apply()

    /**
     * Receiving when the "everyone" window is closed: "off", or "mine" ("My devices
     * only": always reachable by paired devices, invisible to everyone else).
     */
    var receiveBase: String
        get() = sp.getString("receiveBase", "off").takeIf { it == "mine" } ?: "off"
        set(value) = sp.edit().putString("receiveBase", if (value == "mine") "mine" else "off").apply()

    /** Offer to send each new screenshot to the last device used (needs photo access). */
    var screenshotOffer: Boolean
        get() = sp.getBoolean("screenshotOffer", false)
        set(value) = sp.edit().putBoolean("screenshotOffer", value).apply()

    /** The device files were last sent to, for one-tap clipboard and screenshot sends. */
    var lastDeviceId: String?
        get() = sp.getString("lastDeviceId", null)
        set(value) = sp.edit().putString("lastDeviceId", value).apply()

    /**
     * Smart arrival: images to Pictures/CrossDrop, videos to Movies/CrossDrop, audio to
     * Music/CrossDrop, everything else (and folders) to Download/CrossDrop. Off by default.
     */
    var sortByType: Boolean
        get() = sp.getBoolean("sortByType", false)
        set(value) = sp.edit().putBoolean("sortByType", value).apply()

    /** Turbo (experimental, §9.10): multi-file sends ask the receiver for parallel connections. */
    var turbo: Boolean
        get() = sp.getBoolean("turbo", false)
        set(value) = sp.edit().putBoolean("turbo", value).apply()

    var notificationPermissionAsked: Boolean
        get() = sp.getBoolean("notificationAsked", false)
        set(value) = sp.edit().putBoolean("notificationAsked", value).apply()

    private fun defaultName(): String =
        Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() }
            ?: Build.MODEL
}

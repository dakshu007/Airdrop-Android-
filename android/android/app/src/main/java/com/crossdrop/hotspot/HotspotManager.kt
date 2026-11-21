package com.crossdrop.hotspot

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper

/**
 * Experimental "no router" mode: the phone opens a local-only Wi-Fi hotspot
 * (no internet sharing) that the Mac joins, so both are on one network.
 * Android 13+ only, so it needs no location permission. Untested on real
 * hardware; the UI says so.
 */
class HotspotManager(context: Context, private val onChange: () -> Unit) {
    private val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null

    /** 'off' | 'starting' | 'on' | 'failed' | 'unsupported' */
    @Volatile var state: String = if (Build.VERSION.SDK_INT >= 33) "off" else "unsupported"
        private set
    @Volatile var ssid: String? = null
        private set
    @Volatile var password: String? = null
        private set
    @Volatile var error: String? = null
        private set

    val isOn: Boolean get() = state == "on"

    /** Caller must hold NEARBY_WIFI_DEVICES. */
    @android.annotation.SuppressLint("MissingPermission")
    fun start() {
        if (Build.VERSION.SDK_INT < 33 || wifi == null) {
            state = "unsupported"
            onChange()
            return
        }
        if (state == "on" || state == "starting") return
        state = "starting"
        error = null
        onChange()
        try {
            wifi.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                override fun onStarted(res: WifiManager.LocalOnlyHotspotReservation) {
                    reservation = res
                    val config = res.softApConfiguration
                    ssid = config.wifiSsid?.toString()?.trim('"') ?: @Suppress("DEPRECATION") config.ssid
                    password = config.passphrase
                    state = "on"
                    onChange()
                }

                override fun onStopped() {
                    clear("off")
                }

                override fun onFailed(reason: Int) {
                    error = when (reason) {
                        WifiManager.LocalOnlyHotspotCallback.ERROR_TETHERING_DISALLOWED -> "tethering_disallowed"
                        WifiManager.LocalOnlyHotspotCallback.ERROR_INCOMPATIBLE_MODE -> "incompatible_mode"
                        WifiManager.LocalOnlyHotspotCallback.ERROR_NO_CHANNEL -> "no_channel"
                        else -> "failed"
                    }
                    clear("failed")
                }
            }, main)
        } catch (e: SecurityException) {
            error = "permission"
            clear("failed")
        } catch (e: IllegalStateException) {
            error = "busy"
            clear("failed")
        }
    }

    fun stop() {
        reservation?.close()
        clear("off")
    }

    private fun clear(newState: String) {
        reservation = null
        ssid = null
        password = null
        state = newState
        onChange()
    }
}

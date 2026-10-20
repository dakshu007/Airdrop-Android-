package com.crossdrop.network

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager

/** Tracks whether a Wi-Fi or Ethernet network is up, and holds a multicast lock on request. */
class NetworkMonitor(context: Context, private val onChange: (Boolean) -> Unit) {
    private val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val networks = HashSet<Network>()
    private val multicastLock = wifi.createMulticastLock("crossdrop-mdns").apply { setReferenceCounted(false) }

    @Volatile
    var localNetwork: Boolean = false
        private set

    fun start() {
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
            .build()
        cm.registerNetworkCallback(request, object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = update { networks.add(network) }
            override fun onLost(network: Network) = update { networks.remove(network) }
        })
    }

    private fun update(change: () -> Unit) {
        val now = synchronized(networks) {
            change()
            networks.isNotEmpty()
        }
        if (now != localNetwork) {
            localNetwork = now
            onChange(now)
        }
    }

    /** Held only while discovery or receiving is active. */
    fun setMulticast(held: Boolean) {
        runCatching { if (held) multicastLock.acquire() else if (multicastLock.isHeld) multicastLock.release() }
    }
}

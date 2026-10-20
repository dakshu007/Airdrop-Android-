package com.crossdrop.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import com.crossdrop.core.Platform
import com.crossdrop.core.Protocol
import java.net.Inet4Address

/** A CrossDrop device seen via DNS-SD. Display hints only; the handshake proves identity. */
data class DiscoveredDevice(
    val deviceId: String,
    val name: String,
    val platform: Platform,
    val host: String,
    val port: Int,
    val serviceName: String,
)

/**
 * Browses `_crossdrop._tcp` with the system NSD service. Runs only while a
 * discovery screen is visible (callers start/stop it). Resolves are serialised
 * because NsdManager allows one resolve at a time on many Android versions.
 */
@Suppress("DEPRECATION") // resolveService/host: still functional; the API 34 replacements need extra lifecycle handling.
class NsdDiscovery(
    context: Context,
    private val ownDeviceId: () -> String,
    private val onFound: (DiscoveredDevice) -> Unit,
    private val onLost: (serviceName: String) -> Unit,
    private val onError: (String?) -> Unit,
) {
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val main = Handler(Looper.getMainLooper())
    private var listener: NsdManager.DiscoveryListener? = null
    private val queue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false

    val isActive: Boolean get() = listener != null

    fun start() {
        main.post {
            if (listener != null) return@post
            val l = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(serviceType: String) = onError(null)
                override fun onDiscoveryStopped(serviceType: String) {}
                override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                    main.post {
                        listener = null
                        onError("nsd_failed")
                    }
                }
                override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
                override fun onServiceFound(info: NsdServiceInfo) {
                    main.post {
                        if (listener == null) return@post
                        queue.removeAll { it.serviceName == info.serviceName }
                        queue.addLast(info)
                        pump()
                    }
                }
                override fun onServiceLost(info: NsdServiceInfo) {
                    main.post { onLost(info.serviceName) }
                }
            }
            listener = l
            try {
                nsd.discoverServices(Protocol.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
            } catch (e: Exception) {
                listener = null
                onError("nsd_failed")
            }
        }
    }

    fun stop() {
        main.post {
            val l = listener ?: return@post
            listener = null
            queue.clear()
            runCatching { nsd.stopServiceDiscovery(l) }
        }
    }

    private fun pump() {
        if (resolving || listener == null) return
        val info = queue.removeFirstOrNull() ?: return
        resolving = true
        try {
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    main.post {
                        resolving = false
                        if (errorCode == NsdManager.FAILURE_ALREADY_ACTIVE) {
                            queue.addLast(info)
                            main.postDelayed({ pump() }, 300)
                        } else {
                            pump()
                        }
                    }
                }

                override fun onServiceResolved(resolved: NsdServiceInfo) {
                    main.post {
                        resolving = false
                        parse(resolved)?.let { if (listener != null) onFound(it) }
                        pump()
                    }
                }
            })
        } catch (e: Exception) {
            resolving = false
            main.post { pump() }
        }
    }

    private fun parse(info: NsdServiceInfo): DiscoveredDevice? {
        val attrs = info.attributes ?: return null
        fun attr(k: String) = attrs[k]?.let { String(it, Charsets.UTF_8) }
        val id = attr("id") ?: return null
        if (!Protocol.isValidDeviceId(id) || id == ownDeviceId()) return null
        if ((attr("v")?.toIntOrNull() ?: 0) < Protocol.VERSION) return null
        val platform = runCatching { Platform.fromWire(attr("p") ?: "") }.getOrNull() ?: return null
        val address = info.host ?: return null
        // Prefer IPv4 when available: link-local IPv6 needs a scope id that is easy to lose.
        val host = if (address is Inet4Address) address.hostAddress else address.hostAddress?.substringBefore('%')
        return DiscoveredDevice(id, info.serviceName, platform, host ?: return null, info.port, info.serviceName)
    }
}

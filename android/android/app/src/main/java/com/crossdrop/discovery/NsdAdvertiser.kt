package com.crossdrop.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import com.crossdrop.core.Platform
import com.crossdrop.core.Protocol

/** Publishes this device as `_crossdrop._tcp` while receiving is on (§2). No secrets in the record. */
class NsdAdvertiser(context: Context, private val onError: (String?) -> Unit) {
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var listener: NsdManager.RegistrationListener? = null

    @Synchronized
    fun register(name: String, port: Int, deviceId: String) {
        unregister()
        val info = NsdServiceInfo().apply {
            serviceName = truncateUtf8(name, 63)
            serviceType = Protocol.SERVICE_TYPE
            setPort(port)
            setAttribute("v", Protocol.VERSION.toString())
            setAttribute("id", deviceId)
            setAttribute("p", Platform.ANDROID.wire)
        }
        val l = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) = onError(null)
            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = onError("nsd_failed")
            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {}
            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
        }
        listener = l
        try {
            nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, l)
        } catch (e: Exception) {
            listener = null
            onError("nsd_failed")
        }
    }

    @Synchronized
    fun unregister() {
        val l = listener ?: return
        listener = null
        runCatching { nsd.unregisterService(l) }
    }

    private fun truncateUtf8(s: String, max: Int): String {
        var out = s
        while (out.toByteArray(Charsets.UTF_8).size > max) out = out.dropLast(1)
        return out.ifBlank { "Android" }
    }
}

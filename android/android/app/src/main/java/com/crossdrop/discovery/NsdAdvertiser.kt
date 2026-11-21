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

    /** Random name for "My devices only" (§9.5), stable while the process lives. */
    private val privateName = "CrossDrop-" + java.util.UUID.randomUUID().toString().take(8)

    /** [private]: "My devices only" — random name and `m=1`, so strangers don't see the device's name. */
    @Synchronized
    fun register(name: String, port: Int, deviceId: String, private: Boolean = false) {
        unregister()
        val info = NsdServiceInfo().apply {
            serviceName = if (private) privateName else truncateUtf8(name, 63)
            serviceType = Protocol.SERVICE_TYPE
            setPort(port)
            setAttribute("v", Protocol.VERSION.toString())
            setAttribute("id", deviceId)
            setAttribute("p", Platform.ANDROID.wire)
            if (private) setAttribute("m", "1")
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

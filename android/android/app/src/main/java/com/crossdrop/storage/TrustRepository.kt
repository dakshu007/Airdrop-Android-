package com.crossdrop.storage

import android.content.Context
import android.util.Base64
import com.crossdrop.core.Json
import com.crossdrop.core.PeerInfo
import com.crossdrop.core.Platform
import com.crossdrop.core.TrustStore
import com.crossdrop.core.TrustedPeer
import com.crossdrop.core.deviceIdFor

/**
 * Paired devices, persisted in private app storage. Records hold only public
 * keys and display metadata, so they are not secret, but they decide who may
 * connect without pairing, and are only ever written after both users confirmed.
 */
class TrustRepository(context: Context) : TrustStore {
    private val sp = context.getSharedPreferences("crossdrop_trust", Context.MODE_PRIVATE)
    private val peers = LinkedHashMap<String, TrustedPeer>()
    var onChange: (() -> Unit)? = null

    init {
        for ((key, value) in sp.all) {
            val raw = value as? String ?: continue
            runCatching { decode(raw) }.getOrNull()?.takeIf { it.deviceId == key && deviceIdFor(it.identityKey) == key }?.let { peers[key] = it }
        }
    }

    @Synchronized
    override fun get(deviceId: String): TrustedPeer? = peers[deviceId]

    @Synchronized
    fun all(): List<TrustedPeer> = peers.values.sortedByDescending { it.lastUsedAt ?: it.pairedAt }

    override fun trust(peer: PeerInfo) {
        synchronized(this) {
            val existing = peers[peer.deviceId]
            val now = System.currentTimeMillis()
            save(TrustedPeer(peer.deviceId, peer.identityKey, peer.name, peer.platform, now, existing?.lastUsedAt, existing?.autoAccept ?: false))
        }
        onChange?.invoke()
    }

    override fun touch(deviceId: String, name: String) {
        synchronized(this) {
            val p = peers[deviceId] ?: return
            save(p.copy(name = name, lastUsedAt = System.currentTimeMillis()))
        }
        onChange?.invoke()
    }

    fun forget(deviceId: String) {
        synchronized(this) {
            peers.remove(deviceId)
            sp.edit().remove(deviceId).apply()
        }
        onChange?.invoke()
    }

    fun setAutoAccept(deviceId: String, enabled: Boolean) {
        synchronized(this) {
            val p = peers[deviceId] ?: return
            save(p.copy(autoAccept = enabled))
        }
        onChange?.invoke()
    }

    private fun save(p: TrustedPeer) {
        peers[p.deviceId] = p
        sp.edit().putString(p.deviceId, encode(p)).apply()
    }

    private fun encode(p: TrustedPeer): String = Json.write(
        linkedMapOf(
            "deviceId" to p.deviceId,
            "identityKey" to Base64.encodeToString(p.identityKey, Base64.NO_WRAP),
            "name" to p.name,
            "platform" to p.platform.wire,
            "pairedAt" to p.pairedAt,
            "lastUsedAt" to p.lastUsedAt,
            "autoAccept" to p.autoAccept,
        ),
    )

    @Suppress("UNCHECKED_CAST")
    private fun decode(raw: String): TrustedPeer {
        val m = Json.parse(raw) as Map<String, Any?>
        return TrustedPeer(
            deviceId = m["deviceId"] as String,
            identityKey = Base64.decode(m["identityKey"] as String, Base64.NO_WRAP),
            name = m["name"] as String,
            platform = Platform.fromWire(m["platform"] as String),
            pairedAt = m["pairedAt"] as Long,
            lastUsedAt = m["lastUsedAt"] as Long?,
            autoAccept = m["autoAccept"] as Boolean,
        )
    }
}

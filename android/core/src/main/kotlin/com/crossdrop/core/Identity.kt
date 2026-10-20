package com.crossdrop.core

import java.security.PrivateKey

/** The device's long-term identity (§1.1). Platforms back it with secure storage. */
interface IdentityKey {
    /** X9.63 uncompressed public key, 65 bytes. */
    val publicKey: ByteArray

    /** ECDSA P-256 / SHA-256 signature in DER. */
    fun sign(data: ByteArray): ByteArray
}

val IdentityKey.fingerprint: String get() = Hashing.sha256(publicKey).toHex()
val IdentityKey.deviceId: String get() = fingerprint.substring(0, 32)

fun deviceIdFor(identityKey: ByteArray): String = Hashing.sha256(identityKey).toHex().substring(0, 32)

/** Identity held in memory; used by the CLI and tests. */
class SoftwareIdentity(private val privateKey: PrivateKey, override val publicKey: ByteArray) : IdentityKey {
    override fun sign(data: ByteArray): ByteArray = P256.sign(privateKey, data)

    companion object {
        fun fromScalar(scalar: ByteArray) =
            SoftwareIdentity(P256.privateKeyFromScalar(scalar), P256.encode(P256.publicKeyFromScalar(scalar)))

        fun generate(): Pair<SoftwareIdentity, ByteArray> {
            val kp = P256.generate()
            val s = (kp.private as java.security.interfaces.ECPrivateKey).s
            val raw = s.toByteArray().let { if (it.size > 32) it.copyOfRange(it.size - 32, it.size) else ByteArray(32 - it.size) + it }
            return SoftwareIdentity(kp.private, P256.encode(kp.public as java.security.interfaces.ECPublicKey)) to raw
        }
    }
}

/** Local record of a paired device (§5). */
data class TrustedPeer(
    val deviceId: String,
    val identityKey: ByteArray,
    val name: String,
    val platform: Platform,
    val pairedAt: Long,
    val lastUsedAt: Long?,
    val autoAccept: Boolean,
) {
    val fingerprint: String get() = Hashing.sha256(identityKey).toHex()
}

/** Persistent set of paired devices. Implementations must be thread-safe. */
interface TrustStore {
    fun get(deviceId: String): TrustedPeer?
    fun trust(peer: PeerInfo)
    fun touch(deviceId: String, name: String)
}

class InMemoryTrustStore : TrustStore {
    private val peers = java.util.concurrent.ConcurrentHashMap<String, TrustedPeer>()
    override fun get(deviceId: String) = peers[deviceId]
    override fun trust(peer: PeerInfo) {
        peers[peer.deviceId] = TrustedPeer(peer.deviceId, peer.identityKey, peer.name, peer.platform, System.currentTimeMillis(), null, false)
    }
    override fun touch(deviceId: String, name: String) {
        peers.computeIfPresent(deviceId) { _, p -> p.copy(name = name, lastUsedAt = System.currentTimeMillis()) }
    }
}

package com.crossdrop.core

import java.nio.ByteBuffer
import java.security.interfaces.ECPublicKey

/** Result of a successful handshake (§4). */
class HandshakeResult(
    val peer: PeerInfo,
    /** Six-digit short authentication string for pairing. */
    val sas: String,
    val transcriptHash: ByteArray,
)

/** Pure functions shared by both handshake roles; exposed for test vectors. */
object KeySchedule {
    fun lp(b: ByteArray): ByteArray = ByteBuffer.allocate(4).putInt(b.size).array() + b

    fun transcriptHash(hello: ByteArray, challenge: ByteArray, clientEph: ByteArray, clientIdentity: ByteArray): ByteArray =
        Hashing.sha256(Protocol.LABEL_TRANSCRIPT, lp(hello), lp(challenge), lp(clientEph), lp(clientIdentity))

    fun c2s(shared: ByteArray, th: ByteArray) = Hashing.hkdf(shared, th, Protocol.LABEL_C2S, 32)
    fun s2c(shared: ByteArray, th: ByteArray) = Hashing.hkdf(shared, th, Protocol.LABEL_S2C, 32)

    fun sas(th: ByteArray): String {
        val h = Hashing.sha256(Protocol.LABEL_SAS, th)
        val v = ByteBuffer.wrap(h, 0, 4).int.toLong() and 0xffffffffL
        return String.format("%06d", v % 1_000_000)
    }
}

object Handshake {
    private fun peerError(msg: Message): Nothing {
        val code = ErrorCode.fromWire(msg.optString("code", 64) ?: "internal")
        throw ProtocolException(code, "peer error", remote = true)
    }

    private fun parsePeer(msg: Message, identityKey: ByteArray, trust: TrustStore): PeerInfo {
        val deviceId = msg.string("deviceId", 32)
        if (!Protocol.isValidDeviceId(deviceId) || deviceIdFor(identityKey) != deviceId) {
            throw ProtocolException(ErrorCode.AUTH_FAILED, "deviceId does not match identity key")
        }
        val known = trust.get(deviceId)
        if (known != null && !known.identityKey.contentEquals(identityKey)) {
            throw ProtocolException(ErrorCode.AUTH_FAILED, "identity key changed")
        }
        return PeerInfo(
            deviceId = deviceId,
            name = cleanDisplayName(msg.string("name", 1024)),
            platform = Platform.fromWire(msg.string("platform", 16)),
            appVersion = msg.string("appVersion", 64),
            identityKey = identityKey,
        )
    }

    /** Client role: runs §4 over a fresh connection and switches it to encrypted records. */
    fun client(conn: Connection, identity: IdentityKey, local: LocalInfo, trust: TrustStore): HandshakeResult {
        val eph = P256.generate()
        val ephPub = P256.encode(eph.public as ECPublicKey)
        val hello = Json.encode(
            Message.build(
                "hello",
                "minV" to Protocol.VERSION,
                "deviceId" to identity.deviceId,
                "name" to local.name,
                "platform" to local.platform.wire,
                "appVersion" to local.appVersion,
                "ephCommit" to B64.encode(Hashing.sha256(ephPub)),
            ),
        )
        mapIo { conn.writePlain(hello) }

        val challengeBytes = conn.readPlain()
        val challenge = Message.parse(challengeBytes)
        if (challenge.type == "error") peerError(challenge)
        if (challenge.type != "auth.challenge") throw ProtocolException(ErrorCode.UNEXPECTED_MESSAGE)
        if (challenge.version != Protocol.VERSION.toLong()) throw ProtocolException(ErrorCode.UNSUPPORTED_VERSION)
        val serverIdentity = challenge.bytes("identityKey", P256.PUBLIC_KEY_SIZE)
        val serverEph = P256.decode(challenge.bytes("ephPub", P256.PUBLIC_KEY_SIZE))
        val peer = parsePeer(challenge, serverIdentity, trust)

        val th = KeySchedule.transcriptHash(hello, challengeBytes, ephPub, identity.publicKey)
        val signature = identity.sign(Protocol.LABEL_CLIENT_PROOF + th)
        mapIo {
            conn.writePlain(
                Message.build(
                    "auth.proof",
                    "ephPub" to B64.encode(ephPub),
                    "identityKey" to B64.encode(identity.publicKey),
                    "signature" to B64.encode(signature),
                ),
            )
        }

        val proof = Message.parse(conn.readPlain())
        if (proof.type == "error") peerError(proof)
        if (proof.type != "auth.proof") throw ProtocolException(ErrorCode.UNEXPECTED_MESSAGE)
        if (!P256.verify(serverIdentity, Protocol.LABEL_SERVER_PROOF + th, proof.bytes("signature"))) {
            throw ProtocolException(ErrorCode.AUTH_FAILED, "server proof invalid")
        }

        val shared = P256.ecdh(eph.private, serverEph)
        conn.startEncrypted(KeySchedule.c2s(shared, th), KeySchedule.s2c(shared, th), "crossdrop-client-reader")
        return HandshakeResult(peer, KeySchedule.sas(th), th)
    }

    /**
     * Server role. [admit] runs after `hello` is parsed and may return an error
     * code (busy, not_receiving) to refuse the connection politely.
     */
    fun server(
        conn: Connection,
        identity: IdentityKey,
        local: LocalInfo,
        trust: TrustStore,
        admit: () -> ErrorCode? = { null },
    ): HandshakeResult {
        val helloBytes = conn.readPlain()
        val hello = Message.parse(helloBytes)
        if (hello.type != "hello") throw ProtocolException(ErrorCode.UNEXPECTED_MESSAGE)
        val maxV = hello.version
        val minV = hello.long("minV", 0, Int.MAX_VALUE.toLong())
        if (Protocol.VERSION < minV || Protocol.VERSION > maxV) throw ProtocolException(ErrorCode.UNSUPPORTED_VERSION)
        val clientDeviceId = hello.string("deviceId", 32)
        if (!Protocol.isValidDeviceId(clientDeviceId)) throw ProtocolException(ErrorCode.BAD_MESSAGE, "bad deviceId")
        val commit = hello.bytes("ephCommit", 32)
        // Validate the remaining hello fields up front.
        hello.string("name", 1024)
        Platform.fromWire(hello.string("platform", 16))
        hello.string("appVersion", 64)

        admit()?.let { throw ProtocolException(it, "refused") }

        val eph = P256.generate()
        val ephPub = P256.encode(eph.public as ECPublicKey)
        val challengeBytes = Json.encode(
            Message.build(
                "auth.challenge",
                "deviceId" to identity.deviceId,
                "name" to local.name,
                "platform" to local.platform.wire,
                "appVersion" to local.appVersion,
                "ephPub" to B64.encode(ephPub),
                "identityKey" to B64.encode(identity.publicKey),
            ),
        )
        mapIo { conn.writePlain(challengeBytes) }

        val proof = Message.parse(conn.readPlain())
        if (proof.type == "error") peerError(proof)
        if (proof.type != "auth.proof") throw ProtocolException(ErrorCode.UNEXPECTED_MESSAGE)
        val clientEphBytes = proof.bytes("ephPub", P256.PUBLIC_KEY_SIZE)
        val clientIdentity = proof.bytes("identityKey", P256.PUBLIC_KEY_SIZE)
        if (!Hashing.sha256(clientEphBytes).contentEquals(commit)) {
            throw ProtocolException(ErrorCode.AUTH_FAILED, "commitment mismatch")
        }
        val clientEph = P256.decode(clientEphBytes)
        val peer = parsePeer(hello, clientIdentity, trust)
        val th = KeySchedule.transcriptHash(helloBytes, challengeBytes, clientEphBytes, clientIdentity)
        if (!P256.verify(clientIdentity, Protocol.LABEL_CLIENT_PROOF + th, proof.bytes("signature"))) {
            throw ProtocolException(ErrorCode.AUTH_FAILED, "client proof invalid")
        }

        val signature = identity.sign(Protocol.LABEL_SERVER_PROOF + th)
        mapIo { conn.writePlain(Message.build("auth.proof", "signature" to B64.encode(signature))) }

        val shared = P256.ecdh(eph.private, clientEph)
        conn.startEncrypted(KeySchedule.s2c(shared, th), KeySchedule.c2s(shared, th), "crossdrop-server-reader")
        return HandshakeResult(peer, KeySchedule.sas(th), th)
    }
}

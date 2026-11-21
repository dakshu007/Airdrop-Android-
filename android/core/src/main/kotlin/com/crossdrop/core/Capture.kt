package com.crossdrop.core

import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap

/** What a capture request asks for (§9.7). */
enum class CaptureKind(val wire: String) {
    /** Take a new photo with the camera. */
    PHOTO("photo"),

    /** Pick existing photos or files. */
    PICK("pick");

    companion object {
        fun fromWire(s: String): CaptureKind =
            entries.firstOrNull { it.wire == s } ?: throw ProtocolException(ErrorCode.BAD_MESSAGE, "unknown capture kind")
    }
}

/**
 * A paired device asked this one to capture something and send it back (§9.7).
 * The answer goes to [replyHost] (the address this request came from) on [replyPort],
 * or to wherever discovery finds [peer] when the requester gave no port.
 */
class CaptureRequest internal constructor(
    val requestId: String,
    val kind: CaptureKind,
    val peer: PeerInfo,
    val replyHost: String,
    val replyPort: Int?,
)

/**
 * Capture requests this device sent and still expects an answer to (§9.7). An offer
 * whose `requestId` matches one of these, from the device it was sent to, is accepted
 * without asking, once, within [Protocol.CAPTURE_REQUEST_TTL_MS].
 */
class CaptureRequests {
    private class Entry(val deviceId: String, val expiresAt: Long)
    private val pending = ConcurrentHashMap<String, Entry>()

    /** Registers [requestId] as sent to [deviceId]. */
    fun expect(requestId: String, deviceId: String, ttlMs: Long = Protocol.CAPTURE_REQUEST_TTL_MS) {
        require(Protocol.isValidTransferId(requestId)) { "bad requestId" }
        val now = System.currentTimeMillis()
        pending.entries.removeIf { it.value.expiresAt < now }
        pending[requestId] = Entry(deviceId, now + ttlMs)
    }

    /** Uses up [requestId] if it is outstanding for [deviceId]. A different device never consumes it. */
    fun redeem(requestId: String, deviceId: String): Boolean {
        val entry = pending[requestId] ?: return false
        if (entry.deviceId != deviceId) return false
        if (!pending.remove(requestId, entry)) return false
        return entry.expiresAt >= System.currentTimeMillis()
    }

    fun cancel(requestId: String) {
        pending.remove(requestId)
    }

    fun cancelAll() = pending.clear()

    val outstanding: Int get() {
        val now = System.currentTimeMillis()
        return pending.values.count { it.expiresAt >= now }
    }
}

/** Requester side of §9.7: asks a paired device to take a photo (or pick files) and send it back. */
object CaptureClient {
    /**
     * Connects to [host]:[port], sends `capture.request` and returns its requestId once
     * the other device accepted. Throws [TransferRejectedException] ("declined") when it
     * declined, [ProtocolException] otherwise. [replyPort] is this device's listening port;
     * [expect] (usually the local server's [CrossDropServer.captureRequests]) learns the
     * requestId before it is sent, so the answer is accepted without a prompt.
     * The other device must already be paired; with [pairing] set, an unpaired one is
     * paired first (normal code comparison).
     */
    fun request(
        identity: IdentityKey,
        local: LocalInfo,
        trust: TrustStore,
        host: String,
        port: Int,
        expectedDeviceId: String?,
        kind: CaptureKind,
        replyPort: Int?,
        expect: CaptureRequests? = null,
        pairing: PairingEvents? = null,
    ): String {
        require(replyPort == null || replyPort in 1..65535) { "bad reply port" }
        val socket = Socket()
        try {
            socket.connect(InetSocketAddress(host, port), Protocol.CONNECT_TIMEOUT_MS)
        } catch (e: IOException) {
            runCatching { socket.close() }
            throw ProtocolException(ErrorCode.UNREACHABLE, "connect failed")
        }
        val c = Connection(socket)
        var encrypted = false
        var requestId: String? = null
        try {
            val hs = Handshake.client(c, identity, local, trust)
            encrypted = true
            if (expectedDeviceId != null && hs.peer.deviceId != expectedDeviceId) {
                throw ProtocolException(ErrorCode.PEER_CHANGED_IDENTITY, "unexpected device")
            }
            if (trust.get(hs.peer.deviceId) == null) {
                if (pairing == null) throw ProtocolException(ErrorCode.PAIRING_REQUIRED, "not paired")
                QrPairingClient.pair(c, hs, null, pairing, trust)
            }
            val id = Sessions.newTransferId()
            requestId = id
            expect?.expect(id, hs.peer.deviceId)
            val msg = Message.build("capture.request", "requestId" to id, "kind" to kind.wire)
            if (replyPort != null) (msg as MutableMap<String, Any?>)["port"] = replyPort
            mapIo { c.sendControl(msg) }
            // The other app may ask its user first, so allow a human's time.
            val item = c.next(Protocol.HUMAN_DECISION_TIMEOUT_MS + 5_000)
            val reply = (item as? Connection.Incoming.Control)?.message
                ?: throw ProtocolException(ErrorCode.UNEXPECTED_MESSAGE, "expected capture.ack")
            if (reply.type != "capture.ack") Sessions.handleUnexpected(reply)
            if (reply.string("requestId", 64) != id) throw ProtocolException(ErrorCode.BAD_MESSAGE, "wrong requestId")
            if (!reply.bool("accepted")) throw TransferRejectedException("declined")
            return id
        } catch (e: ProtocolException) {
            requestId?.let { expect?.cancel(it) }
            if (!e.remote && !c.isClosed && e.code != ErrorCode.CONNECTION_LOST && e.code != ErrorCode.PAIRING_REQUIRED) {
                c.sendErrorAndClose(e.code, encrypted)
            }
            throw e
        } catch (e: TransferRejectedException) {
            requestId?.let { expect?.cancel(it) }
            throw e
        } finally {
            c.close()
        }
    }
}

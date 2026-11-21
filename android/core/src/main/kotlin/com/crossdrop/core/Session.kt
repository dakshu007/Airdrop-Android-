package com.crossdrop.core

import java.util.UUID
import java.util.concurrent.CompletableFuture

enum class Role { SENDER, RECEIVER }

/** A pairing confirmation shown to the local user (§5). */
class PairingPrompt internal constructor(
    val sessionId: String,
    val peer: PeerInfo,
    /** Six digits. */
    val code: String,
    val role: Role,
    val expiresAt: Long,
) {
    internal val decision = CompletableFuture<Boolean>()
    @Volatile internal var mine = false

    /**
     * Called by the UI with the user's answer. [mine] means "this is my device":
     * once paired, its files arrive without asking (§9.4). Later calls are ignored.
     */
    fun respond(accept: Boolean, mine: Boolean = false) {
        if (!decision.isDone) this.mine = mine
        decision.complete(accept)
    }
}

/**
 * One-time tokens a receiver shows inside a pairing QR code (§9.4). Scanning the
 * code proves the scanner is physically in front of this screen, so a pairing that
 * presents a valid token skips the code comparison on this side.
 */
class PairingTokens {
    private class Entry(val expiresAt: Long, val mine: Boolean)
    private val tokens = java.util.concurrent.ConcurrentHashMap<String, Entry>()
    private val random = java.security.SecureRandom()

    /** A fresh token, valid for [Protocol.PAIRING_TOKEN_TTL_MS]; [mine] is the local "this is my device" choice. */
    fun issue(mine: Boolean): String {
        val bytes = ByteArray(16).also(random::nextBytes)
        val token = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
        val now = System.currentTimeMillis()
        tokens.entries.removeIf { it.value.expiresAt < now }
        tokens[token] = Entry(now + Protocol.PAIRING_TOKEN_TTL_MS, mine)
        return token
    }

    /** Uses up [token]. Returns the "mine" choice it was issued with, or null if it isn't valid. */
    fun redeem(token: String): Boolean? {
        val entry = tokens.remove(token) ?: return null
        return if (entry.expiresAt >= System.currentTimeMillis()) entry.mine else null
    }

    fun revokeAll() = tokens.clear()
}

/** What a client learned from a pairing QR code (§9.4). */
data class QrPairing(
    val token: String,
    /** SHA-256 of the receiver's identity key, lowercase hex: the code is only good for that device. */
    val fingerprint: String,
    /** The scanning user's "this is my device" choice. */
    val mine: Boolean,
)

/**
 * Pairing that needs no prompt on this side: a QR token was presented or verified (§9.4),
 * or a Drip Room proof was (§9.9). [expiresAt] (epoch ms) makes the stored trust temporary.
 */
internal class AutoPair(val mine: Boolean, val expiresAt: Long? = null)

/** An incoming offer awaiting the local user's decision (§6.2). */
class IncomingOffer internal constructor(
    val transferId: String,
    val peer: PeerInfo,
    val files: List<OfferFile>,
    val expiresAt: Long,
    /** Files, or a link / text that the receiver handles without saving a file (§9.2). */
    val kind: OfferKind = OfferKind.FILES,
    /**
     * Set only when this offer answers a capture request this device sent to the same
     * peer (§9.7); such an offer is accepted without asking.
     */
    val requestId: String? = null,
    /** Seconds after which the sender asks that the received items be deleted (§9.8). */
    val expiresAfter: Long? = null,
) {
    val totalBytes: Long = files.sumOf { it.size }
    internal val decision = CompletableFuture<Boolean>()

    fun respond(accept: Boolean) {
        decision.complete(accept)
    }
}

/** Callbacks shared by both roles for the pairing step. */
interface PairingEvents {
    fun onPairingPrompt(prompt: PairingPrompt)

    /** The local user accepted; waiting for the other device. */
    fun onPairingWaitingForPeer(prompt: PairingPrompt) {}

    /** The prompt is finished (paired, declined, timed out or connection lost). */
    fun onPairingClosed(prompt: PairingPrompt, paired: Boolean)
}

private class PairingDecision(val prompt: PairingPrompt, val accept: Boolean)
private class OfferDecision(val offer: IncomingOffer, val accept: Boolean)

internal object Pairing {
    /**
     * Runs the §5 exchange once `pair.request` has been sent or received.
     * [remoteAlreadyAccepted]: the peer's `pair.confirm true` was already read (§9.9).
     * [confirmExtra]: fields added to an automatic `pair.confirm` (the room proof, §9.9).
     */
    fun run(
        conn: Connection,
        hs: HandshakeResult,
        role: Role,
        events: PairingEvents,
        trust: TrustStore,
        auto: AutoPair? = null,
        remoteAlreadyAccepted: Boolean = false,
        confirmExtra: Map<String, Any?> = emptyMap(),
    ) {
        val deadline = System.currentTimeMillis() + Protocol.HUMAN_DECISION_TIMEOUT_MS
        val prompt = PairingPrompt(UUID.randomUUID().toString(), hs.peer, hs.sas, role, deadline)
        // Only a prompt the user answers feeds a decision into the connection.
        if (auto == null) prompt.decision.thenAccept { conn.inject(PairingDecision(prompt, it)) }
        var paired = false
        if (auto == null) events.onPairingPrompt(prompt)
        try {
            var localAccepted = false
            var remoteAccepted = remoteAlreadyAccepted
            if (auto != null) {
                // The QR code (or room proof) already proved who is on each side: answer for the user.
                val confirm = Message.build("pair.confirm", "accepted" to true) as MutableMap<String, Any?>
                confirm.putAll(confirmExtra)
                mapIo { conn.sendControl(confirm) }
                localAccepted = true
            }
            while (!(localAccepted && remoteAccepted)) {
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0) {
                    runCatching { conn.sendControl(Message.build("pair.confirm", "accepted" to false)) }
                    drainPeerAnswer(conn, remoteAccepted)
                    throw ProtocolException(ErrorCode.TIMEOUT, "pairing timed out")
                }
                when (val item = conn.next(remaining)) {
                    is Connection.Incoming.Local -> {
                        val d = item.value as? PairingDecision ?: continue
                        if (d.prompt !== prompt || localAccepted) continue
                        try {
                            mapIo { conn.sendControl(Message.build("pair.confirm", "accepted" to d.accept)) }
                        } catch (e: ProtocolException) {
                            // The peer may have declined and closed before our answer went out;
                            // report its answer rather than the broken connection.
                            throw peerDecline(conn) ?: e
                        }
                        if (!d.accept) {
                            drainPeerAnswer(conn, remoteAccepted)
                            throw ProtocolException(ErrorCode.PAIRING_REJECTED, "declined locally")
                        }
                        localAccepted = true
                        if (!remoteAccepted) events.onPairingWaitingForPeer(prompt)
                    }
                    is Connection.Incoming.Control -> {
                        val msg = item.message
                        when (msg.type) {
                            "pair.confirm" -> {
                                if (!msg.bool("accepted")) throw ProtocolException(ErrorCode.PAIRING_REJECTED, "declined by peer", remote = true)
                                remoteAccepted = true
                            }
                            else -> Sessions.handleUnexpected(msg)
                        }
                    }
                    else -> throw ProtocolException(ErrorCode.UNEXPECTED_MESSAGE, "data during pairing")
                }
            }
            trust.trust(hs.peer, auto?.mine ?: prompt.mine, auto?.expiresAt)
            paired = true
        } finally {
            prompt.decision.complete(false)
            if (auto == null) events.onPairingClosed(prompt, paired)
        }
    }

    /**
     * After declining, waits briefly for the peer's own answer before the
     * connection is closed. Closing a TCP socket with unread data sends a reset,
     * which can discard our decline before the peer reads it.
     */
    private fun drainPeerAnswer(conn: Connection, alreadyAnswered: Boolean) {
        if (alreadyAnswered) return
        val deadline = System.currentTimeMillis() + 1_500
        while (true) {
            val remaining = deadline - System.currentTimeMillis()
            if (remaining <= 0) return
            val item = try {
                conn.next(remaining)
            } catch (e: ProtocolException) {
                return
            }
            if ((item as? Connection.Incoming.Control)?.message?.type == "pair.confirm") return
        }
    }

    /** After a failed write, looks briefly for a `pair.confirm false` the peer sent before closing. */
    private fun peerDecline(conn: Connection): ProtocolException? {
        val deadline = System.currentTimeMillis() + 1_000
        while (true) {
            val remaining = deadline - System.currentTimeMillis()
            if (remaining <= 0) return null
            val item = try {
                conn.next(remaining)
            } catch (e: ProtocolException) {
                return null
            }
            val msg = (item as? Connection.Incoming.Control)?.message ?: continue
            if (msg.type == "pair.confirm" && msg.fields["accepted"] == false) {
                return ProtocolException(ErrorCode.PAIRING_REJECTED, "declined by peer", remote = true)
            }
        }
    }

    /** Waits for the local decision on [offer] while watching for a cancel from the sender. */
    fun awaitOfferDecision(conn: Connection, offer: IncomingOffer): Boolean {
        offer.decision.thenAccept { conn.inject(OfferDecision(offer, it)) }
        while (true) {
            val remaining = offer.expiresAt - System.currentTimeMillis()
            if (remaining <= 0) return false
            val item = try {
                conn.next(remaining)
            } catch (e: ProtocolException) {
                if (e.code == ErrorCode.TIMEOUT) return false
                throw e
            }
            when (item) {
                is Connection.Incoming.Local -> {
                    val d = item.value as? OfferDecision ?: continue
                    if (d.offer === offer) return d.accept
                }
                is Connection.Incoming.Control -> Sessions.handleUnexpected(item.message)
                else -> throw ProtocolException(ErrorCode.UNEXPECTED_MESSAGE, "data before accept")
            }
        }
    }
}

internal object Sessions {
    /** Turns peer `error` / `transfer.cancel` into exceptions; anything else is unexpected. */
    fun handleUnexpected(msg: Message): Nothing {
        when (msg.type) {
            "error" -> throw ProtocolException(ErrorCode.fromWire(msg.optString("code", 64) ?: "internal"), "peer error", remote = true)
            "transfer.cancel" -> throw ProtocolException(ErrorCode.CANCELLED, "cancelled by peer", remote = true)
            else -> throw ProtocolException(ErrorCode.UNEXPECTED_MESSAGE, "unexpected ${msg.type}")
        }
    }

    fun newTransferId(): String = UUID.randomUUID().toString()
}

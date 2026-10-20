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

    /** Called by the UI with the user's answer. Later calls are ignored. */
    fun respond(accept: Boolean) {
        decision.complete(accept)
    }
}

/** An incoming offer awaiting the local user's decision (§6.2). */
class IncomingOffer internal constructor(
    val transferId: String,
    val peer: PeerInfo,
    val files: List<OfferFile>,
    val expiresAt: Long,
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
    /** Runs the §5 exchange once `pair.request` has been sent or received. */
    fun run(conn: Connection, hs: HandshakeResult, role: Role, events: PairingEvents, trust: TrustStore) {
        val deadline = System.currentTimeMillis() + Protocol.HUMAN_DECISION_TIMEOUT_MS
        val prompt = PairingPrompt(UUID.randomUUID().toString(), hs.peer, hs.sas, role, deadline)
        prompt.decision.thenAccept { conn.inject(PairingDecision(prompt, it)) }
        var paired = false
        events.onPairingPrompt(prompt)
        try {
            var localAccepted = false
            var remoteAccepted = false
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
            trust.trust(hs.peer)
            paired = true
        } finally {
            prompt.decision.complete(false)
            events.onPairingClosed(prompt, paired)
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

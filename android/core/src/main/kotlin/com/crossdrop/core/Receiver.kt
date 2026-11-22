package com.crossdrop.core

import java.io.IOException
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/** Where received files go. Platform-specific (MediaStore on Android, a directory on the JVM). */
interface ReceiveStorage {
    /** Free bytes at the destination, or Long.MAX_VALUE if unknown. */
    fun availableBytes(): Long

    /** Opens a temporary, not-yet-visible file for [name] (already sanitised). */
    fun begin(name: String, mime: String?, size: Long): PartialFile

    /**
     * Opens a temporary file inside the folders [path] (already sanitised, §9.1).
     * [resumeKey] names this file for resuming (§9.3); when [resumeFrom] > 0 the bytes
     * kept under that key are reopened and new bytes are appended after them.
     */
    fun begin(name: String, mime: String?, size: Long, path: List<String>, resumeKey: String?, resumeFrom: Long): PartialFile =
        if (resumeFrom > 0) throw IOException("resume not supported") else begin(name, mime, size)

    /** Bytes kept from an earlier interrupted transfer under [resumeKey] (§9.3), or 0. */
    fun resumableBytes(resumeKey: String): Long = 0
}

interface PartialFile {
    val output: OutputStream

    /** Bytes already in the file when it was reopened to resume. */
    val existingBytes: Long get() = 0

    /** Reads the bytes already present, so they can be hashed again. */
    fun openExisting(): java.io.InputStream? = null

    /** Makes the verified file visible under a non-colliding name. */
    fun commit(): SavedFile

    /** Deletes the temporary file. Must not throw. */
    fun abort()

    /** Keeps the bytes received so far for a later resume (§9.3). Must not throw. */
    fun keepForResume() = abort()
}

/** [location] is a content URI on Android, an absolute path on the JVM. */
data class SavedFile(val displayName: String, val location: String)

interface ReceiverEvents : PairingEvents {
    fun isReceiving(): Boolean

    /** Ask the user about [offer] unless auto-accepted; the UI calls offer.respond(). */
    fun onOffer(offer: IncomingOffer)

    fun onOfferClosed(offer: IncomingOffer) {}

    fun onTransferStarted(transfer: IncomingTransfer) {}

    fun onProgress(transfer: IncomingTransfer, fileIndex: Int, fileBytes: Long, totalBytes: Long) {}

    fun onFileSaved(transfer: IncomingTransfer, fileIndex: Int, saved: SavedFile) {}

    fun onCompleted(transfer: IncomingTransfer) {}

    /** [transfer] is null when the failure happened before an offer was accepted. */
    fun onFailed(transfer: IncomingTransfer?, peer: PeerInfo?, error: ProtocolException) {}

    fun onRejected(offer: IncomingOffer, reason: String) {}

    /** A link or text offer arrived and was verified (§9.2). Nothing is saved to storage. */
    fun onTextReceived(transfer: IncomingTransfer, kind: OfferKind, text: String) {}

    /**
     * A paired device asks this one to take a photo or pick files and send them back (§9.7).
     * Return true to accept; the app then sends the result to `request.replyHost` /
     * `request.replyPort` with `OutgoingTransfer(requestId = request.requestId)`.
     * Called on the connection's thread; the requester waits up to the human timeout.
     */
    fun onCaptureRequest(peer: PeerInfo, request: CaptureRequest): Boolean = false
}

/** An accepted incoming transfer; [cancel] may be called from any thread. */
class IncomingTransfer internal constructor(
    val transferId: String,
    val peer: PeerInfo,
    val files: List<OfferFile>,
    private val conn: Connection,
    val kind: OfferKind = OfferKind.FILES,
    /** Set when this transfer answers a capture request this device sent (§9.7). */
    val requestId: String? = null,
    /** Seconds after which the sender asks that the received items be deleted (§9.8); the app does the deleting. */
    val expiresAfter: Long? = null,
) {
    val totalBytes: Long = files.sumOf { it.size }
    internal val cancelled = AtomicBoolean(false)
    /** Set when the sender spreads this transfer over several connections (§9.10). */
    @Volatile internal var group: IncomingTurbo? = null
    /** Bytes received so far over all connections. */
    internal val received = AtomicLong(0)
    /** Serialises event callbacks when files arrive on several connections at once (§9.10). */
    internal val eventLock = Any()

    /** Connections this transfer used, the main one included: more than 1 with Turbo (§9.10). */
    val streams: Int get() = group?.streams ?: 1

    fun cancel() {
        if (!cancelled.compareAndSet(false, true)) return
        runCatching { conn.sendControl(Message.build("transfer.cancel", "transferId" to transferId, "reason" to "user")) }
        conn.close()
        // A Turbo transfer ends on every connection (§9.10).
        group?.fail(ProtocolException(ErrorCode.CANCELLED, "cancelled"), conn)
    }
}

/**
 * Listens for inbound connections (server role) and runs each one on its own
 * thread, at most [Protocol.MAX_INBOUND_CONNECTIONS] at a time.
 */
class CrossDropServer(
    private val identity: IdentityKey,
    private val local: () -> LocalInfo,
    private val trust: TrustStore,
    private val storage: ReceiveStorage,
    private val events: ReceiverEvents,
    /** "My devices only" (§9.5): only paired devices, or a valid QR token or room proof, get past the handshake. */
    private val privateMode: () -> Boolean = { false },
    /** Drip Rooms this device is in (§9.9); pass the same registry to outgoing transfers. */
    val rooms: Rooms = Rooms(),
    /** Turbo (§9.10): let a sender add connections to a multi-file transfer. Read per offer. */
    private val turbo: () -> Boolean = { true },
) {
    /** Tokens for pairing QR codes shown by this device (§9.4). */
    val pairingTokens = PairingTokens()

    /** Capture requests this device sent and expects an answer to (§9.7). */
    val captureRequests = CaptureRequests()
    private var serverSocket: ServerSocket? = null
    private var acceptThread: Thread? = null
    private val active = AtomicInteger(0)
    private val turboGroups = TurboRegistry()

    /** Inbound connections currently open (each Turbo connection counts, §9.10). */
    val activeConnections: Int get() = active.get()
    private val pool: ExecutorService = Executors.newCachedThreadPool { r ->
        Thread(r, "crossdrop-inbound").apply { isDaemon = true }
    }

    /** Binds to [port] (0 = any) on all interfaces and returns the bound port. */
    @Synchronized
    fun start(port: Int = 0, bindAddress: InetAddress? = null): Int {
        serverSocket?.let { return it.localPort }
        val ss = ServerSocket()
        ss.reuseAddress = true
        ss.bind(InetSocketAddress(bindAddress, port), 16)
        serverSocket = ss
        acceptThread = Thread({ acceptLoop(ss) }, "crossdrop-accept").apply {
            isDaemon = true
            start()
        }
        return ss.localPort
    }

    @Synchronized
    fun stop() {
        runCatching { serverSocket?.close() }
        serverSocket = null
        acceptThread = null
    }

    val port: Int? get() = serverSocket?.localPort

    private fun acceptLoop(ss: ServerSocket) {
        while (!ss.isClosed) {
            val socket = try {
                ss.accept()
            } catch (e: IOException) {
                break
            }
            val count = active.incrementAndGet()
            pool.execute {
                try {
                    InboundSession(Connection(socket), count).run()
                } finally {
                    active.decrementAndGet()
                }
            }
        }
    }

    private inner class InboundSession(private val conn: Connection, private val slot: Int) {
        private var encrypted = false
        private var peer: PeerInfo? = null
        private var transfer: IncomingTransfer? = null
        private var partial: PartialFile? = null
        /** The Turbo group this (main) session owns (§9.10). */
        private var group: IncomingTurbo? = null
        /** The Turbo group this extra connection joined (§9.10). */
        private var joined: IncomingTurbo? = null
        /** This connection asked to join a Turbo transfer (§9.10): its failures are never reported as a transfer's. */
        private var sideConnection = false

        fun run() {
            try {
                runInner()
            } catch (e: ProtocolException) {
                fail(e)
            } catch (e: Exception) {
                fail(ProtocolException(ErrorCode.INTERNAL, e.javaClass.simpleName))
            } finally {
                conn.close()
            }
        }

        private fun fail(e: ProtocolException) {
            val t = transfer ?: joined?.transfer
            var error = if (t != null && t.cancelled.get()) ProtocolException(ErrorCode.CANCELLED, "cancelled") else e
            // In a Turbo transfer the first failure on any connection decides for all of them (§9.10).
            val g = group ?: joined
            var first = true
            if (g != null) {
                first = g.fail(error, conn)
                error = g.error ?: error
            }
            // A dropped connection keeps the file so far for a resume (§9.3); anything else discards it.
            if (error.code == ErrorCode.CONNECTION_LOST || error.code == ErrorCode.TIMEOUT) partial?.keepForResume() else partial?.abort()
            if (first && !error.remote && error.code != ErrorCode.CANCELLED && error.code != ErrorCode.CONNECTION_LOST && !conn.isClosed) {
                conn.sendErrorAndClose(error.code, encrypted)
            }
            // The main session reports the transfer; an extra connection (joined or refused) never does.
            if (!sideConnection) events.onFailed(t, peer, error)
        }

        private fun runInner() {
            val hs = Handshake.server(conn, identity, local(), trust) {
                when {
                    !events.isReceiving() -> ErrorCode.NOT_RECEIVING
                    slot > Protocol.MAX_INBOUND_CONNECTIONS -> ErrorCode.BUSY
                    else -> null
                }
            }
            encrypted = true
            peer = hs.peer

            var paired = false
            while (true) {
                val msg = try {
                    nextControl(Protocol.STREAM_IDLE_TIMEOUT_MS)
                } catch (e: ProtocolException) {
                    // A pairing-only session (QR code, §9.4) simply closes after pairing.
                    if (paired && e.code == ErrorCode.CONNECTION_LOST) return
                    throw e
                }
                val untrusted = trust.get(hs.peer.deviceId) == null
                when (msg.type) {
                    "pair.request" -> {
                        val mine = msg.optString("token", 64)?.let { pairingTokens.redeem(it) }
                        val room = verifyRoom(msg, hs)
                        if (untrusted && mine == null && room == null && privateMode()) throw ProtocolException(ErrorCode.NOT_RECEIVING, "paired devices only")
                        // Already paired with this exact key (the sender forgot us): confirm without asking
                        // again, keeping the existing auto-accept choice. The sender still compares codes,
                        // unless it proved room membership and we prove ours back (§9.9).
                        val known = trust.get(hs.peer.deviceId)?.takeIf { it.identityKey.contentEquals(hs.peer.identityKey) }
                        val auto = when {
                            mine != null -> AutoPair(mine)
                            known != null && known.expiresAt == null -> AutoPair(known.autoAccept)
                            room != null -> AutoPair(false, maxOf(room.expiresAtMillis, known?.expiresAt ?: 0L))
                            known != null -> AutoPair(known.autoAccept, known.expiresAt)
                            else -> null
                        }
                        val extra: Map<String, Any?> = if (room != null) {
                            mapOf("room" to linkedMapOf("id" to room.id, "proof" to B64.encode(room.confirmProof(hs.transcriptHash))))
                        } else {
                            emptyMap()
                        }
                        Pairing.run(conn, hs, Role.RECEIVER, events, trust, auto, confirmExtra = extra)
                        paired = true
                    }
                    "capture.request" -> {
                        if (untrusted) {
                            if (privateMode()) throw ProtocolException(ErrorCode.NOT_RECEIVING, "paired devices only")
                            // No pairing in this flow (§9.7): the requester must already be paired.
                            throw ProtocolException(ErrorCode.PAIRING_REQUIRED, "capture from unpaired device")
                        }
                        handleCapture(hs.peer, msg)
                        return
                    }
                    "transfer.offer" -> {
                        if (untrusted) {
                            if (privateMode()) throw ProtocolException(ErrorCode.NOT_RECEIVING, "paired devices only")
                            mapIo { conn.sendControl(Message.build("error", "code" to ErrorCode.PAIRING_REQUIRED.wire)) }
                            continue
                        }
                        handleOffer(hs.peer, msg)
                        return
                    }
                    "transfer.join" -> {
                        sideConnection = true
                        if (untrusted) {
                            if (privateMode()) throw ProtocolException(ErrorCode.NOT_RECEIVING, "paired devices only")
                            // No pairing on an extra connection (§9.10).
                            throw ProtocolException(ErrorCode.PAIRING_REQUIRED, "join from unpaired device")
                        }
                        handleJoin(hs.peer, msg)
                        return
                    }
                    else -> Sessions.handleUnexpected(msg)
                }
            }
        }

        /**
         * The room a `pair.request` proves membership of (§9.9), or null. A malformed `room`
         * field is `bad_message`; an unknown room or a wrong proof just means no room, so
         * pairing falls back to comparing codes. Only stores that can expire trust take part.
         */
        private fun verifyRoom(msg: Message, hs: HandshakeResult): Room? {
            val raw = msg.fields["room"] ?: return null
            @Suppress("UNCHECKED_CAST")
            val m = Message(((raw as? Map<String, Any?>) ?: throw ProtocolException(ErrorCode.BAD_MESSAGE, "bad room")) + mapOf("type" to "room", "v" to 1L))
            val id = m.string("id", 64)
            if (!Rooms.isValidId(id)) throw ProtocolException(ErrorCode.BAD_MESSAGE, "bad room id")
            val proof = m.bytes("proof", 32)
            if (!trust.supportsTrustExpiry) return null
            return rooms.verify(id, proof, hs.transcriptHash)
        }

        /** §9.7: validate, ask the app, answer `capture.ack`, done. */
        private fun handleCapture(peer: PeerInfo, msg: Message) {
            val requestId = msg.string("requestId", 64)
            if (!Protocol.isValidTransferId(requestId)) throw ProtocolException(ErrorCode.BAD_MESSAGE, "bad requestId")
            val kind = CaptureKind.fromWire(msg.string("kind", 16))
            val replyPort = if (msg.fields["port"] == null) null else msg.long("port", 1, 65535).toInt()
            val host = conn.socket.inetAddress?.hostAddress ?: throw ProtocolException(ErrorCode.INTERNAL, "no peer address")
            val accepted = events.onCaptureRequest(peer, CaptureRequest(requestId, kind, peer, host, replyPort))
            mapIo { conn.sendControl(Message.build("capture.ack", "requestId" to requestId, "accepted" to accepted)) }
            // Give the requester a moment to read the answer and close first.
            runCatching { conn.next(2_000) }
        }

        private fun nextControl(timeoutMs: Long): Message {
            val item = conn.next(timeoutMs)
            return (item as? Connection.Incoming.Control)?.message
                ?: throw ProtocolException(ErrorCode.UNEXPECTED_MESSAGE, "expected control message")
        }

        private fun reject(transferId: String, reason: String) {
            mapIo { conn.sendControl(Message.build("transfer.reject", "transferId" to transferId, "reason" to reason)) }
        }

        /** An extra connection of a Turbo transfer (§9.10): check the token, then take files. */
        private fun handleJoin(peer: PeerInfo, msg: Message) {
            val transferId = msg.transferId()
            val token = msg.string("token", 64)
            val g = turboGroups.find(transferId) ?: throw ProtocolException(ErrorCode.UNEXPECTED_MESSAGE, "no such transfer")
            g.join(conn, peer.deviceId, token)?.let { throw ProtocolException(it, "join refused") }
            joined = g
            mapIo { conn.sendControl(Message.build("transfer.joined", "transferId" to transferId)) }
            receiveTurbo(g, isMain = false)
        }

        private fun handleOffer(peer: PeerInfo, msg: Message) {
            val transferId = msg.transferId()
            val files = OfferFile.parseOffer(msg)
            val kind = OfferFile.parseKind(msg, files)
            val expiresAfter = if (msg.fields["expiresAfter"] == null) null else msg.long("expiresAfter", Protocol.MIN_EXPIRES_AFTER, Protocol.MAX_EXPIRES_AFTER)
            val parallel = if (msg.fields["parallel"] == null) null else msg.long("parallel", 2, Protocol.MAX_TURBO_STREAMS.toLong()).toInt()
            val rawRequestId = msg.optString("requestId", 64)
            if (rawRequestId != null && !Protocol.isValidTransferId(rawRequestId)) throw ProtocolException(ErrorCode.BAD_MESSAGE, "bad requestId")
            // Only an answer to a capture request we sent to this very device counts (§9.7). It is
            // used up only once the offer gets past the local checks below, so a retry still counts.
            val candidate = rawRequestId?.takeIf { captureRequests.isOutstanding(it, peer.deviceId) }
            val expiresAt = System.currentTimeMillis() + Protocol.HUMAN_DECISION_TIMEOUT_MS
            var offer = IncomingOffer(transferId, peer, files, expiresAt, kind, candidate, expiresAfter)

            if (!events.isReceiving()) {
                reject(transferId, "not_receiving")
                events.onRejected(offer, "not_receiving")
                return
            }
            if (storage.availableBytes() < offer.totalBytes + Protocol.STORAGE_MARGIN_BYTES) {
                reject(transferId, "insufficient_storage")
                events.onRejected(offer, "insufficient_storage")
                return
            }
            val requestId = candidate?.takeIf { captureRequests.redeem(it, peer.deviceId) }
            // Another connection used it up in the meantime: a normal offer after all.
            if (requestId != candidate) offer = IncomingOffer(transferId, peer, files, expiresAt, kind, null, expiresAfter)

            val accepted = if (requestId != null || trust.get(peer.deviceId)?.autoAccept == true) {
                true
            } else {
                events.onOffer(offer)
                try {
                    Pairing.awaitOfferDecision(conn, offer)
                } finally {
                    offer.respond(false)
                    events.onOfferClosed(offer)
                }
            }
            if (!accepted) {
                val reason = if (System.currentTimeMillis() >= offer.expiresAt) "timeout" else "declined"
                reject(transferId, reason)
                events.onRejected(offer, reason)
                return
            }

            // Offer to continue files a dropped connection left half-received (§9.3).
            val resumeAt = HashMap<Int, Long>()
            if (kind == OfferKind.FILES) {
                for (file in files) {
                    val have = storage.resumableBytes(resumeKey(peer, file))
                    if (have in 1 until file.size) resumeAt[file.fileId] = have
                }
            }
            val accept = Message.build("transfer.accept", "transferId" to transferId)
            if (resumeAt.isNotEmpty()) {
                (accept as MutableMap<String, Any?>)["resume"] = resumeAt.map { (id, offset) -> linkedMapOf("fileId" to id, "offset" to offset) }
            }
            val t = IncomingTransfer(transferId, peer, files, conn, kind, requestId, expiresAfter)
            // Turbo (§9.10): offer extra connections, within the inbound connection limit.
            if (parallel != null && kind == OfferKind.FILES && files.size >= 2 && turbo()) {
                val max = minOf(parallel, Protocol.MAX_TURBO_STREAMS, files.size, Protocol.MAX_INBOUND_CONNECTIONS - active.get() + 1)
                if (max >= 2) {
                    val g = IncomingTurbo(transferId, peer.deviceId, Turbo.newToken(), max, files, resumeAt, conn, turboGroups)
                    g.transfer = t
                    if (turboGroups.register(g)) {
                        group = g
                        t.group = g
                        (accept as MutableMap<String, Any?>)["join"] = linkedMapOf("token" to g.token, "max" to max)
                    }
                }
            }
            mapIo { conn.sendControl(accept) }
            transfer = t
            events.onTransferStarted(t)
            val g = group
            when {
                kind != OfferKind.FILES -> receiveText(t)
                g != null -> receiveTurbo(g, isMain = true)
                else -> receiveFiles(t, resumeAt)
            }
            mapIo { conn.sendControl(Message.build("transfer.complete", "transferId" to transferId)) }
            g?.complete()
            trust.touch(peer.deviceId, peer.name)
            events.onCompleted(t)
            // Give the sender a moment to read `transfer.complete` and close first.
            runCatching { conn.next(2_000) }
        }

        private fun nextStart(t: IncomingTransfer, file: OfferFile): Message {
            val start = nextControl(Protocol.STREAM_IDLE_TIMEOUT_MS)
            if (start.type != "transfer.start") Sessions.handleUnexpected(start)
            if (start.transferId() != t.transferId || start.long("fileId", 0, Protocol.MAX_FILES.toLong()).toInt() != file.fileId) {
                throw ProtocolException(ErrorCode.BAD_MESSAGE, "files out of order")
            }
            return start
        }

        /** A link or text payload (§9.2): small, held in memory, verified, never written to storage. */
        private fun receiveText(t: IncomingTransfer) {
            val file = t.files[0]
            nextStart(t, file)
            val buf = java.io.ByteArrayOutputStream(file.size.toInt())
            while (buf.size() < file.size) {
                when (val item = conn.next(Protocol.STREAM_IDLE_TIMEOUT_MS)) {
                    is Connection.Incoming.Data -> {
                        if (buf.size() + item.length > file.size) throw ProtocolException(ErrorCode.BAD_MESSAGE, "more data than announced")
                        buf.write(item.buffer, item.offset, item.length)
                    }
                    is Connection.Incoming.Control -> Sessions.handleUnexpected(item.message)
                    else -> throw ProtocolException(ErrorCode.UNEXPECTED_MESSAGE)
                }
            }
            val bytes = buf.toByteArray()
            if (Hashing.sha256(bytes).toHex() != file.sha256) throw ProtocolException(ErrorCode.INTEGRITY_FAILED, "sha256 mismatch")
            val text = try {
                Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString()
            } catch (e: java.nio.charset.CharacterCodingException) {
                throw ProtocolException(ErrorCode.BAD_MESSAGE, "text is not UTF-8")
            }
            sendProgress(t, file, file.size)
            events.onProgress(t, 0, file.size, file.size)
            events.onTextReceived(t, t.kind, text)
        }

        private fun receiveFiles(t: IncomingTransfer, resumeAt: Map<Int, Long>) {
            for ((index, file) in t.files.withIndex()) {
                receiveOne(t, index, nextStart(t, file), resumeAt, null)
            }
        }

        /**
         * Turbo (§9.10): files arrive on any of the transfer's connections, in any order.
         * The main session returns once every file is verified; an extra connection returns
         * once the transfer has ended. Inactivity is judged over all connections together.
         */
        private fun receiveTurbo(g: IncomingTurbo, isMain: Boolean) {
            val t = g.transfer
            while (!(if (isMain) g.allDone else g.finished)) {
                val item = try {
                    conn.next(TURBO_POLL_MS)
                } catch (e: ProtocolException) {
                    if (e.code == ErrorCode.TIMEOUT) {
                        if (System.currentTimeMillis() - g.lastActivity > Protocol.STREAM_IDLE_TIMEOUT_MS) throw e
                        continue
                    }
                    // Closed because the transfer ended (finished, or failed elsewhere).
                    if (!isMain && g.finished) return
                    throw e
                }
                when (item) {
                    is Connection.Incoming.Local -> continue
                    is Connection.Incoming.Control -> {
                        val start = item.message
                        if (start.type != "transfer.start") Sessions.handleUnexpected(start)
                        if (start.transferId() != t.transferId) throw ProtocolException(ErrorCode.BAD_MESSAGE, "wrong transferId")
                        val index = g.claim(start.long("fileId", 0, Protocol.MAX_FILES.toLong()).toInt())
                        receiveOne(t, index, start, g.resumeAt, g)
                        g.fileDone()
                    }
                    else -> throw ProtocolException(ErrorCode.BAD_MESSAGE, "data outside a file")
                }
            }
            // Completed: let the sender close this extra connection first (it does once it read `transfer.complete`).
            if (!isMain && g.error == null) runCatching { conn.next(2_000) }
        }

        /** Receives, verifies and saves file [index] after its `transfer.start`. */
        private fun receiveOne(t: IncomingTransfer, index: Int, start: Message, resumeAt: Map<Int, Long>, g: IncomingTurbo?) {
            val file = t.files[index]
            // The sender either continues where we offered (§9.3) or starts from 0.
            val offset = (start.fields["offset"] as? Long) ?: 0L
            if (offset != 0L && offset != resumeAt[file.fileId]) throw ProtocolException(ErrorCode.BAD_MESSAGE, "bad offset")

            val name = Sanitizer.fileName(file.name)
            val key = resumeKey(t.peer, file)
            val p = try {
                storage.begin(name, file.mime, file.size, file.path, key, offset)
            } catch (e: IOException) {
                throw ProtocolException(ErrorCode.STORAGE_ERROR, "cannot create file")
            }
            partial = p
            val md = MessageDigest.getInstance("SHA-256")
            var received = 0L
            if (offset > 0) {
                // Hash the bytes kept from last time, so the check still covers the whole file.
                try {
                    val existing = p.openExisting() ?: throw IOException("nothing to resume")
                    existing.use { input ->
                        val buf = ByteArray(Protocol.MAX_DATA_BODY)
                        while (received < offset) {
                            val n = input.read(buf, 0, minOf(buf.size.toLong(), offset - received).toInt())
                            if (n < 0) break
                            md.update(buf, 0, n)
                            received += n
                        }
                    }
                } catch (e: IOException) {
                    throw ProtocolException(ErrorCode.STORAGE_ERROR, "cannot read kept part")
                }
                if (received != offset) throw ProtocolException(ErrorCode.STORAGE_ERROR, "kept part is shorter")
                t.received.addAndGet(offset)
            }
            var lastProgressAt = 0L
            while (received < file.size) {
                when (val item = conn.next(Protocol.STREAM_IDLE_TIMEOUT_MS)) {
                    is Connection.Incoming.Data -> {
                        if (received + item.length > file.size) throw ProtocolException(ErrorCode.BAD_MESSAGE, "more data than announced")
                        try {
                            p.output.write(item.buffer, item.offset, item.length)
                        } catch (e: IOException) {
                            throw ProtocolException(ErrorCode.STORAGE_ERROR, "write failed")
                        }
                        md.update(item.buffer, item.offset, item.length)
                        received += item.length
                        val total = t.received.addAndGet(item.length.toLong())
                        g?.touch()
                        synchronized(t.eventLock) { events.onProgress(t, index, received, total) }
                        val now = System.currentTimeMillis()
                        if (now - lastProgressAt >= Protocol.PROGRESS_INTERVAL_MS) {
                            lastProgressAt = now
                            sendProgress(t, file, received)
                        }
                    }
                    is Connection.Incoming.Control -> Sessions.handleUnexpected(item.message)
                    is Connection.Incoming.Local -> continue
                    else -> throw ProtocolException(ErrorCode.UNEXPECTED_MESSAGE)
                }
            }
            try {
                p.output.close()
            } catch (e: IOException) {
                throw ProtocolException(ErrorCode.STORAGE_ERROR, "close failed")
            }
            if (md.digest().toHex() != file.sha256) throw ProtocolException(ErrorCode.INTEGRITY_FAILED, "sha256 mismatch")
            val saved = try {
                p.commit()
            } catch (e: IOException) {
                throw ProtocolException(ErrorCode.STORAGE_ERROR, "commit failed")
            }
            partial = null
            sendProgress(t, file, received)
            synchronized(t.eventLock) {
                events.onProgress(t, index, received, t.received.get())
                events.onFileSaved(t, index, saved)
            }
        }

        /** Names a half-received file by sender and content, so any later offer of the same file can resume it (§9.3). */
        private fun resumeKey(peer: PeerInfo, file: OfferFile): String =
            Hashing.sha256("CrossDrop/1 resume|${peer.deviceId}|${file.sha256}|${file.size}".toByteArray(Charsets.UTF_8)).toHex()

        private fun sendProgress(t: IncomingTransfer, file: OfferFile, bytes: Long) {
            mapIo {
                conn.sendControl(Message.build("transfer.progress", "transferId" to t.transferId, "fileId" to file.fileId, "bytes" to bytes))
            }
        }
    }
}

/**
 * Saves into a directory: temp file in the same directory, verified, then moved
 * without overwriting. Folder paths (§9.1) become subfolders that never leave the
 * directory or follow symlinks; interrupted files are kept for a day to resume (§9.3).
 */
class DirectoryStorage(private val dir: Path) : ReceiveStorage {
    private val commitLock = Any()

    init {
        Files.createDirectories(dir)
        // Drop kept parts older than the resume window.
        runCatching {
            Files.list(dir).use { stream ->
                stream.filter { it.fileName.toString().startsWith(RESUME_PREFIX) }
                    .filter { System.currentTimeMillis() - Files.getLastModifiedTime(it).toMillis() > Protocol.RESUME_KEEP_MS }
                    .forEach { runCatching { Files.deleteIfExists(it) } }
            }
        }
    }

    override fun availableBytes(): Long = try {
        Files.getFileStore(dir).usableSpace
    } catch (e: IOException) {
        Long.MAX_VALUE
    }

    private fun resumePath(key: String): Path {
        require(Protocol.isValidSha256Hex(key))
        return dir.resolve("$RESUME_PREFIX$key.partial")
    }

    override fun resumableBytes(resumeKey: String): Long {
        val p = resumePath(resumeKey)
        if (!Files.isRegularFile(p, java.nio.file.LinkOption.NOFOLLOW_LINKS)) return 0
        val age = System.currentTimeMillis() - Files.getLastModifiedTime(p).toMillis()
        return if (age > Protocol.RESUME_KEEP_MS) 0 else Files.size(p)
    }

    override fun begin(name: String, mime: String?, size: Long): PartialFile = begin(name, mime, size, emptyList(), null, 0)

    override fun begin(name: String, mime: String?, size: Long, path: List<String>, resumeKey: String?, resumeFrom: Long): PartialFile {
        val kept = resumeKey?.let { resumePath(it) }
        val temp: Path
        val out: OutputStream
        if (resumeFrom > 0) {
            if (kept == null || !Files.isRegularFile(kept, java.nio.file.LinkOption.NOFOLLOW_LINKS) || Files.size(kept) != resumeFrom) {
                throw IOException("kept part changed")
            }
            temp = kept
            out = Files.newOutputStream(temp, java.nio.file.StandardOpenOption.APPEND, java.nio.file.StandardOpenOption.WRITE)
        } else {
            // A fresh start replaces anything kept for this file.
            kept?.let { runCatching { Files.deleteIfExists(it) } }
            temp = dir.resolve(".crossdrop-${UUID.randomUUID()}.partial")
            out = Files.newOutputStream(temp, java.nio.file.StandardOpenOption.CREATE_NEW, java.nio.file.StandardOpenOption.WRITE)
        }
        return object : PartialFile {
            override val output: OutputStream = out.buffered(256 * 1024)
            override val existingBytes: Long = resumeFrom

            override fun openExisting() = if (resumeFrom > 0) Files.newInputStream(temp) else null

            // Files of one Turbo transfer (§9.10) commit concurrently: pick a free name under a lock.
            override fun commit(): SavedFile = synchronized(commitLock) { commitUnderLock() }

            private fun commitUnderLock(): SavedFile {
                val target = folder(path)
                var n = 0
                while (true) {
                    val candidate = if (n == 0) name else Sanitizer.numbered(name, n)
                    val file = target.resolve(candidate)
                    if (file.parent != target) throw IOException("escapes destination")
                    try {
                        if (Files.exists(file, java.nio.file.LinkOption.NOFOLLOW_LINKS)) throw FileAlreadyExistsException(candidate)
                        Files.move(temp, file, StandardCopyOption.ATOMIC_MOVE)
                        // ATOMIC_MOVE may replace on some platforms; the existence check above guards the common case.
                        val shown = (path + candidate).joinToString("/")
                        return SavedFile(shown, file.toAbsolutePath().toString())
                    } catch (e: FileAlreadyExistsException) {
                        n++
                        if (n > 9999) throw IOException("no free name")
                    }
                }
            }

            override fun abort() {
                runCatching { output.close() }
                runCatching { Files.deleteIfExists(temp) }
            }

            override fun keepForResume() {
                runCatching { output.close() }
                if (kept == null) {
                    runCatching { Files.deleteIfExists(temp) }
                } else if (temp != kept) {
                    runCatching { Files.move(temp, kept, StandardCopyOption.REPLACE_EXISTING) }
                }
            }
        }
    }

    /** Creates the folders for [path] under the destination, refusing symlinks and anything outside it. */
    private fun folder(path: List<String>): Path {
        var current = dir
        for (part in path) {
            val next = current.resolve(part).normalize()
            if (next.parent != current || !next.startsWith(dir)) throw IOException("escapes destination")
            if (Files.isSymbolicLink(next)) throw IOException("symlink in path")
            if (!Files.exists(next, java.nio.file.LinkOption.NOFOLLOW_LINKS)) Files.createDirectory(next)
            if (!Files.isDirectory(next, java.nio.file.LinkOption.NOFOLLOW_LINKS)) throw IOException("not a folder")
            current = next
        }
        return current
    }

    private companion object {
        const val RESUME_PREFIX = ".crossdrop-resume-"
    }
}

/** How often a Turbo session re-checks the shared transfer state while its connection is quiet (§9.10). */
private const val TURBO_POLL_MS = 5_000L

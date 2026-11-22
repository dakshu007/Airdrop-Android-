package com.crossdrop.core

import java.io.IOException
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** A file to send. [size] may be null when the source cannot report it; it is measured while hashing. */
class OutgoingFile(
    val name: String,
    val size: Long?,
    val mime: String?,
    /** Folders above the file inside a sent folder, outermost first (§9.1). */
    val path: List<String> = emptyList(),
    val open: () -> InputStream,
) {
    companion object {
        /** A link or text payload (§9.2) as the single "file" of an offer. */
        fun text(name: String, text: String): OutgoingFile {
            val bytes = text.toByteArray(Charsets.UTF_8)
            require(bytes.size <= Protocol.MAX_TEXT_PAYLOAD) { "text too long" }
            return OutgoingFile(name, bytes.size.toLong(), "text/plain; charset=utf-8") { bytes.inputStream() }
        }
    }
}

enum class SendStage { PREPARING, CONNECTING, PAIRING, WAITING_FOR_ACCEPTANCE, TRANSFERRING }

interface SenderEvents : PairingEvents {
    fun onStage(stage: SendStage)

    /** Hashing finished; sizes are now exact. */
    fun onPrepared(files: List<OfferFile>) {}

    fun onConnected(peer: PeerInfo) {}

    /** Bytes written to the connection so far (all files). Called once per record. */
    fun onBytesSent(total: Long) {}

    /** Receiver-reported progress for one file (§6.3). */
    fun onReceiverProgress(fileIndex: Int, bytes: Long) {}
}

/**
 * One outgoing transfer (client role). [run] blocks until the transfer
 * finishes and throws [ProtocolException] / [TransferRejectedException] on failure.
 * [cancel] may be called from any thread.
 */
class OutgoingTransfer(
    private val identity: IdentityKey,
    private val local: LocalInfo,
    private val trust: TrustStore,
    private val host: String,
    private val port: Int,
    /** When known from discovery, the handshake must reach exactly this device. */
    private val expectedDeviceId: String?,
    private val files: List<OutgoingFile>,
    private val events: SenderEvents,
    val transferId: String = Sessions.newTransferId(),
    /** Files, or a link / text the receiver handles without saving (§9.2). */
    private val kind: OfferKind = OfferKind.FILES,
    /** Set when pairing from a scanned QR code (§9.4). */
    private val qr: QrPairing? = null,
    /** The capture request this transfer answers (§9.7); the requester accepts it without asking. */
    val requestId: String? = null,
    /** Asks the receiver to delete what it saved after this many seconds (§9.8). */
    val expiresAfter: Long? = null,
    /** A Drip Room shared with the receiver (§9.9): pairing proves membership instead of comparing codes. */
    private val room: Room? = null,
    /**
     * Turbo (§9.10): up to this many connections for a multi-file transfer, 1 (off) to 4.
     * Used only when the receiver agrees; otherwise the transfer runs on one connection.
     */
    val turbo: Int = 1,
) {
    private val cancelled = AtomicBoolean(false)
    @Volatile private var conn: Connection? = null
    @Volatile private var encrypted = false
    @Volatile private var group: OutgoingTurbo? = null
    private val sentTotal = AtomicLong(0)
    /** Serialises event callbacks when several connections stream at once (§9.10). */
    private val eventsLock = Any()

    /** Connections this transfer used, the main one included: more than 1 with Turbo (§9.10). */
    val streams: Int get() = group?.streams ?: 1

    init {
        require(files.isNotEmpty() && files.size <= Protocol.MAX_FILES)
        require(turbo in 1..Protocol.MAX_TURBO_STREAMS) { "turbo out of range" }
        require(requestId == null || Protocol.isValidTransferId(requestId)) { "bad requestId" }
        require(expiresAfter == null || expiresAfter in Protocol.MIN_EXPIRES_AFTER..Protocol.MAX_EXPIRES_AFTER) { "expiresAfter out of range" }
    }

    fun cancel() {
        if (!cancelled.compareAndSet(false, true)) return
        group?.let { g ->
            for (side in g.sides) {
                runCatching { side.sendControl(Message.build("transfer.cancel", "transferId" to transferId, "reason" to "user")) }
                side.close()
            }
        }
        val c = conn ?: return
        if (encrypted) runCatching { c.sendControl(Message.build("transfer.cancel", "transferId" to transferId, "reason" to "user")) }
        c.close()
    }

    val isCancelled: Boolean get() = cancelled.get()

    fun run(): PeerInfo {
        try {
            return runInner()
        } catch (e: ProtocolException) {
            if (cancelled.get()) throw ProtocolException(ErrorCode.CANCELLED, "cancelled")
            val c = conn
            if (c != null && !e.remote && !c.isClosed && e.code != ErrorCode.CONNECTION_LOST && e.code != ErrorCode.CANCELLED) {
                c.sendErrorAndClose(e.code, encrypted)
            }
            throw e
        } finally {
            conn?.close()
        }
    }

    private fun checkCancelled() {
        if (cancelled.get()) throw ProtocolException(ErrorCode.CANCELLED, "cancelled")
    }

    private fun runInner(): PeerInfo {
        events.onStage(SendStage.PREPARING)
        val offerFiles = files.mapIndexed { index, f -> prepare(index, f) }
        events.onPrepared(offerFiles)
        checkCancelled()

        events.onStage(SendStage.CONNECTING)
        val socket = Socket()
        try {
            socket.connect(InetSocketAddress(host, port), Protocol.CONNECT_TIMEOUT_MS)
        } catch (e: IOException) {
            runCatching { socket.close() }
            throw ProtocolException(ErrorCode.UNREACHABLE, "connect failed")
        }
        val c = Connection(socket)
        conn = c
        checkCancelled()

        val hs = Handshake.client(c, identity, local, trust)
        encrypted = true
        if (expectedDeviceId != null && hs.peer.deviceId != expectedDeviceId) {
            throw ProtocolException(ErrorCode.PEER_CHANGED_IDENTITY, "unexpected device")
        }
        events.onConnected(hs.peer)
        checkCancelled()

        var pairedThisSession = false
        if (trust.get(hs.peer.deviceId) == null) {
            events.onStage(SendStage.PAIRING)
            QrPairingClient.pair(c, hs, qr, events, trust, room)
            pairedThisSession = true
        }

        val offer = Message.build("transfer.offer", "transferId" to transferId, "files" to offerFiles.map { it.toJson() })
        if (kind != OfferKind.FILES) (offer as MutableMap<String, Any?>)["kind"] = kind.wire
        // Turbo (§9.10): ask for extra connections when there is more than one file.
        val parallel = if (turbo >= 2 && kind == OfferKind.FILES && offerFiles.size >= 2) minOf(turbo, offerFiles.size) else null
        if (parallel != null) (offer as MutableMap<String, Any?>)["parallel"] = parallel
        var join: Turbo.Join? = null
        if (requestId != null) (offer as MutableMap<String, Any?>)["requestId"] = requestId
        if (expiresAfter != null) (offer as MutableMap<String, Any?>)["expiresAfter"] = expiresAfter
        events.onStage(SendStage.WAITING_FOR_ACCEPTANCE)
        mapIo { c.sendControl(offer) }
        while (true) {
            val item = c.next(Protocol.HUMAN_DECISION_TIMEOUT_MS + 5_000)
            val msg = (item as? Connection.Incoming.Control)?.message
                ?: throw ProtocolException(ErrorCode.UNEXPECTED_MESSAGE, "expected decision")
            when (msg.type) {
                "transfer.accept" -> {
                    if (msg.transferId() != transferId) throw ProtocolException(ErrorCode.BAD_MESSAGE, "wrong transferId")
                    resumeAt = parseResume(msg, offerFiles)
                    join = Turbo.parseJoin(msg, parallel)
                    break
                }
                "transfer.reject" -> throw TransferRejectedException(msg.optString("reason", 64) ?: "declined")
                "error" -> {
                    val code = ErrorCode.fromWire(msg.optString("code", 64) ?: "internal")
                    if (code == ErrorCode.PAIRING_REQUIRED && !pairedThisSession) {
                        events.onStage(SendStage.PAIRING)
                        mapIo { c.sendControl(Message.build("pair.request")) }
                        Pairing.run(c, hs, Role.SENDER, events, trust)
                        pairedThisSession = true
                        events.onStage(SendStage.WAITING_FOR_ACCEPTANCE)
                        mapIo { c.sendControl(offer) }
                    } else {
                        throw ProtocolException(code, "peer error", remote = true)
                    }
                }
                else -> Sessions.handleUnexpected(msg)
            }
        }

        events.onStage(SendStage.TRANSFERRING)
        val j = join
        if (j != null) {
            streamTurbo(c, hs.peer, offerFiles, j)
        } else {
            var nextIndex = 0
            sendFiles(c, offerFiles, null) { if (nextIndex < offerFiles.size) nextIndex++ else null }
            // Wait for the receiver to verify the last file.
            waitForComplete(c, null)
        }
        trust.touch(hs.peer.deviceId, hs.peer.name)
        return hs.peer
    }

    /** Waits for `transfer.complete` on the main connection, showing the receiver's progress meanwhile. */
    private fun waitForComplete(c: Connection, g: OutgoingTurbo?) {
        while (true) {
            val item = try {
                c.next(if (g == null) Protocol.STREAM_IDLE_TIMEOUT_MS else TURBO_POLL_MS)
            } catch (e: ProtocolException) {
                // With Turbo the other connections may still be busy: judge inactivity over all of them.
                if (g != null && e.code == ErrorCode.TIMEOUT && System.currentTimeMillis() - g.lastActivity <= Protocol.STREAM_IDLE_TIMEOUT_MS) continue
                throw e
            }
            when (item) {
                is Connection.Incoming.Local -> g?.error?.let { throw it }
                is Connection.Incoming.Control -> {
                    val msg = item.message
                    when (msg.type) {
                        "transfer.progress" -> {
                            handleProgress(msg)
                            g?.touch()
                        }
                        "transfer.complete" -> return
                        else -> Sessions.handleUnexpected(msg)
                    }
                }
                else -> throw ProtocolException(ErrorCode.UNEXPECTED_MESSAGE, "data from receiver")
            }
        }
    }

    /**
     * Turbo (§9.10): opens up to `join.max - 1` extra connections to the same receiver.
     * Every connection takes the next file from a shared queue and streams it whole;
     * `transfer.complete` still arrives on the main connection. The first failure on any
     * connection ends them all.
     */
    private fun streamTurbo(c: Connection, peer: PeerInfo, offerFiles: List<OfferFile>, join: Turbo.Join) {
        val g = OutgoingTurbo(c, offerFiles.size, join.max - 1)
        group = g
        val address = InetSocketAddress(c.socket.inetAddress, c.socket.port)
        repeat(join.max - 1) {
            Thread({ sideWorker(g, address, peer, join, offerFiles) }, "crossdrop-turbo").apply {
                isDaemon = true
                start()
            }
        }
        try {
            checkCancelled()
            // Give the extra connections a moment to join, so the files spread over all of them.
            g.awaitSettled(Protocol.TURBO_JOIN_WAIT_MS)
            sendFiles(c, offerFiles, g) { g.next() }
            waitForComplete(c, g)
            g.ended = true
        } catch (e: ProtocolException) {
            val error = if (cancelled.get()) ProtocolException(ErrorCode.CANCELLED, "cancelled") else e
            g.fail(error, wakeMain = false)
            throw g.error ?: error
        } finally {
            g.closeSides()
        }
    }

    /** One extra Turbo connection: handshake, `transfer.join`, then files from the shared queue. */
    private fun sideWorker(g: OutgoingTurbo, address: InetSocketAddress, peer: PeerInfo, join: Turbo.Join, offerFiles: List<OfferFile>) {
        try {
            if (g.ended || cancelled.get()) return
            val socket = Socket()
            try {
                socket.connect(address, Protocol.CONNECT_TIMEOUT_MS)
            } catch (e: IOException) {
                runCatching { socket.close() }
                return
            }
            val c = try {
                Connection(socket)
            } catch (e: IOException) {
                runCatching { socket.close() }
                return
            }
            if (!g.addSide(c)) {
                c.close()
                return
            }
            try {
                val hs = Handshake.client(c, identity, local, trust)
                // The same device, already trusted: no pairing happens on an extra connection.
                if (hs.peer.deviceId != peer.deviceId || !hs.peer.identityKey.contentEquals(peer.identityKey) || trust.get(peer.deviceId) == null) {
                    throw ProtocolException(ErrorCode.PEER_CHANGED_IDENTITY, "another device")
                }
                mapIo { c.sendControl(Message.build("transfer.join", "transferId" to transferId, "token" to join.token)) }
                val reply = (c.next(Protocol.HANDSHAKE_STEP_TIMEOUT_MS.toLong()) as? Connection.Incoming.Control)?.message
                if (reply?.type != "transfer.joined" || reply.fields["transferId"] != transferId) {
                    throw ProtocolException(ErrorCode.UNEXPECTED_MESSAGE, "join refused")
                }
            } catch (e: ProtocolException) {
                // Not joined: its files stay in the queue for the other connections.
                g.sides.remove(c)
                c.close()
                return
            }
            g.joined()
            g.settle()
            try {
                sendFiles(c, offerFiles, g) { g.next() }
                idle(c, g)
            } catch (e: ProtocolException) {
                if (!g.ended && !cancelled.get()) g.fail(e)
            }
        } catch (e: Exception) {
            if (!g.ended && !cancelled.get()) g.fail(ProtocolException(ErrorCode.INTERNAL, e.javaClass.simpleName))
        } finally {
            g.settle()
        }
    }

    /**
     * An extra connection with nothing left to send: shows progress until the transfer
     * ends. Losing it now loses nothing (the main connection decides); a peer error or
     * cancel on it still ends the transfer.
     */
    private fun idle(c: Connection, g: OutgoingTurbo) {
        while (!g.ended) {
            val item = try {
                c.next(TURBO_POLL_MS)
            } catch (e: ProtocolException) {
                if (e.code == ErrorCode.TIMEOUT) continue
                return
            }
            when (item) {
                is Connection.Incoming.Local -> continue
                is Connection.Incoming.Control -> {
                    val msg = item.message
                    if (msg.type != "transfer.progress") Sessions.handleUnexpected(msg)
                    handleProgress(msg)
                    g.touch()
                }
                else -> throw ProtocolException(ErrorCode.UNEXPECTED_MESSAGE, "data from receiver")
            }
        }
    }

    private var resumeAt: Map<Int, Long> = emptyMap()

    /** Files the receiver already holds part of (§9.3): fileId -> bytes to skip. */
    private fun parseResume(msg: Message, offerFiles: List<OfferFile>): Map<Int, Long> {
        val raw = msg.fields["resume"] as? List<*> ?: return emptyMap()
        val sizes = offerFiles.associate { it.fileId to it.size }
        val out = HashMap<Int, Long>()
        for (entry in raw) {
            val m = entry as? Map<*, *> ?: throw ProtocolException(ErrorCode.BAD_MESSAGE, "bad resume entry")
            val id = (m["fileId"] as? Long)?.toInt() ?: throw ProtocolException(ErrorCode.BAD_MESSAGE, "bad resume entry")
            val offset = m["offset"] as? Long ?: throw ProtocolException(ErrorCode.BAD_MESSAGE, "bad resume entry")
            val size = sizes[id] ?: throw ProtocolException(ErrorCode.BAD_MESSAGE, "resume for unknown file")
            if (offset <= 0 || offset >= size) throw ProtocolException(ErrorCode.BAD_MESSAGE, "bad resume offset")
            out[id] = offset
        }
        return out
    }

    private fun prepare(index: Int, file: OutgoingFile): OfferFile {
        val md = MessageDigest.getInstance("SHA-256")
        val buf = ByteArray(Protocol.MAX_DATA_BODY)
        var total = 0L
        try {
            file.open().use { input ->
                while (true) {
                    checkCancelled()
                    val n = input.read(buf)
                    if (n < 0) break
                    md.update(buf, 0, n)
                    total += n
                }
            }
        } catch (e: IOException) {
            throw ProtocolException(ErrorCode.FILE_UNREADABLE, "cannot read source")
        } catch (e: SecurityException) {
            throw ProtocolException(ErrorCode.FILE_UNREADABLE, "no permission for source")
        }
        if (file.size != null && file.size != total) throw ProtocolException(ErrorCode.FILE_UNREADABLE, "size changed")
        val name = file.name.ifBlank { "file" }
        return OfferFile(index, name, total, file.mime?.takeIf { it.toByteArray().size <= 255 }, md.digest().toHex(), file.path)
    }

    private fun handleProgress(msg: Message) {
        if (msg.transferId() != transferId) return
        val fileId = msg.long("fileId", 0, Protocol.MAX_FILES.toLong()).toInt()
        val bytes = msg.long("bytes", 0, Protocol.MAX_SAFE_SIZE)
        synchronized(eventsLock) { events.onReceiverProgress(fileId, bytes) }
    }

    private fun bytesSent(n: Long) {
        val total = sentTotal.addAndGet(n)
        synchronized(eventsLock) { events.onBytesSent(total) }
    }

    /** Streams the files [next] hands out on [c], each whole, until it returns null. */
    private fun sendFiles(c: Connection, offerFiles: List<OfferFile>, g: OutgoingTurbo?, next: () -> Int?) {
        val watchdog: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { r ->
            Thread(r, "crossdrop-send-watchdog").apply { isDaemon = true }
        }
        // A peer that stops reading leaves our write blocked forever; close the socket after 30 s without progress.
        watchdog.scheduleWithFixedDelay({
            val idleMs = (System.nanoTime() - c.lastWriteAt) / 1_000_000
            if (idleMs > Protocol.STREAM_IDLE_TIMEOUT_MS) c.close()
        }, 5, 5, TimeUnit.SECONDS)
        try {
            val buf = ByteArray(Protocol.MAX_DATA_BODY)
            while (true) {
                checkCancelled()
                g?.error?.let { throw it }
                val index = next() ?: break
                val offerFile = offerFiles[index]
                val offset = resumeAt[offerFile.fileId] ?: 0L
                val start = Message.build("transfer.start", "transferId" to transferId, "fileId" to offerFile.fileId)
                if (offset > 0) (start as MutableMap<String, Any?>)["offset"] = offset
                mapIo { c.sendControl(start) }
                var sent = 0L
                try {
                    files[index].open().use { input ->
                        if (offset > 0) {
                            // Continue where the receiver stopped (§9.3).
                            skipFully(input, offset)
                            sent = offset
                            bytesSent(offset)
                        }
                        while (sent < offerFile.size) {
                            checkCancelled()
                            drainIncoming(c, g)
                            val want = minOf(buf.size.toLong(), offerFile.size - sent).toInt()
                            val n = readUpTo(input, buf, want)
                            if (n <= 0) throw ProtocolException(ErrorCode.FILE_UNREADABLE, "source shrank")
                            try {
                                c.sendData(buf, 0, n)
                            } catch (e: IOException) {
                                if (cancelled.get()) throw ProtocolException(ErrorCode.CANCELLED)
                                // The reader may hold the real reason (peer error/cancel).
                                drainIncomingAfterFailure(c)
                                throw ProtocolException(ErrorCode.CONNECTION_LOST, "write failed")
                            }
                            sent += n
                            g?.touch()
                            bytesSent(n.toLong())
                        }
                    }
                } catch (e: IOException) {
                    throw ProtocolException(ErrorCode.FILE_UNREADABLE, "cannot read source")
                }
            }
        } finally {
            watchdog.shutdownNow()
        }
    }

    private fun skipFully(input: InputStream, count: Long) {
        var left = count
        val scratch = ByteArray(64 * 1024)
        while (left > 0) {
            val skipped = input.skip(left)
            if (skipped > 0) {
                left -= skipped
                continue
            }
            val n = input.read(scratch, 0, minOf(scratch.size.toLong(), left).toInt())
            if (n < 0) throw ProtocolException(ErrorCode.FILE_UNREADABLE, "source shrank")
            left -= n
        }
    }

    private fun readUpTo(input: InputStream, buf: ByteArray, want: Int): Int {
        var got = 0
        while (got < want) {
            val n = input.read(buf, got, want - got)
            if (n < 0) break
            got += n
        }
        return got
    }

    /** Handles anything the receiver sent while we stream (progress, cancel, error). */
    private fun drainIncoming(c: Connection, g: OutgoingTurbo?) {
        while (true) {
            val item = c.poll() ?: return
            if (item is Connection.Incoming.Local) {
                // Woken because another Turbo connection failed (§9.10).
                g?.error?.let { throw it }
                continue
            }
            val msg = (item as? Connection.Incoming.Control)?.message
                ?: throw ProtocolException(ErrorCode.UNEXPECTED_MESSAGE, "data from receiver")
            if (msg.type == "transfer.progress") {
                handleProgress(msg)
                g?.touch()
            } else {
                Sessions.handleUnexpected(msg)
            }
        }
    }

    private fun drainIncomingAfterFailure(c: Connection) {
        val deadline = System.currentTimeMillis() + 1_000
        while (System.currentTimeMillis() < deadline) {
            val item = try {
                c.next(deadline - System.currentTimeMillis())
            } catch (e: ProtocolException) {
                return
            }
            val msg = (item as? Connection.Incoming.Control)?.message ?: continue
            if (msg.type != "transfer.progress") Sessions.handleUnexpected(msg)
        }
    }
}

/** How often a Turbo connection re-checks the shared transfer state while it waits (§9.10). */
private const val TURBO_POLL_MS = 5_000L

/**
 * Pairing driven by a scanned QR code (§9.4): the receiver is only accepted if its
 * identity key matches the code, and the code's one-time token lets the receiver
 * skip its prompt. Without a code it is the usual compare-the-numbers pairing.
 */
object QrPairingClient {
    internal fun pair(c: Connection, hs: HandshakeResult, qr: QrPairing?, events: PairingEvents, trust: TrustStore, room: Room? = null) {
        if (qr == null && room != null && room.isActive() && trust.supportsTrustExpiry) {
            RoomPairingClient.pair(c, hs, room, events, trust)
            return
        }
        if (qr == null) {
            mapIo { c.sendControl(Message.build("pair.request")) }
            Pairing.run(c, hs, Role.SENDER, events, trust)
            return
        }
        if (hs.peer.fingerprint != qr.fingerprint) throw ProtocolException(ErrorCode.AUTH_FAILED, "not the device in the QR code")
        mapIo { c.sendControl(Message.build("pair.request", "token" to qr.token)) }
        Pairing.run(c, hs, Role.SENDER, events, trust, AutoPair(qr.mine))
    }

    /** Connects to the device in a QR code, pairs, and closes. Returns the paired peer. */
    fun pairOnly(
        identity: IdentityKey,
        local: LocalInfo,
        trust: TrustStore,
        hosts: List<String>,
        port: Int,
        qr: QrPairing,
        events: PairingEvents,
    ): PeerInfo {
        var lastError: ProtocolException = ProtocolException(ErrorCode.UNREACHABLE, "no address")
        for (host in hosts) {
            val socket = Socket()
            try {
                socket.connect(InetSocketAddress(host, port), Protocol.CONNECT_TIMEOUT_MS)
            } catch (e: IOException) {
                runCatching { socket.close() }
                lastError = ProtocolException(ErrorCode.UNREACHABLE, "connect failed")
                continue
            }
            val c = Connection(socket)
            try {
                val hs = Handshake.client(c, identity, local, trust)
                pair(c, hs, qr, events, trust)
                return hs.peer
            } finally {
                c.close()
            }
        }
        throw lastError
    }
}

/**
 * Pairing inside a Drip Room (§9.9). The sender proves it holds the room key over this
 * exact handshake; a receiver in the same room answers at once with its own proof, and
 * both store trust that ends with the room. Without that answer (unknown room, wrong
 * key, or an older receiver) it falls back to the normal code comparison.
 */
object RoomPairingClient {
    internal fun pair(c: Connection, hs: HandshakeResult, room: Room, events: PairingEvents, trust: TrustStore) {
        val request = Message.build(
            "pair.request",
            "room" to linkedMapOf("id" to room.id, "proof" to B64.encode(room.proof(hs.transcriptHash))),
        )
        mapIo { c.sendControl(request) }
        // A receiver that accepts the proof answers without a human; anything slower means codes.
        val first = try {
            c.next(Protocol.ROOM_ANSWER_WAIT_MS)
        } catch (e: ProtocolException) {
            if (e.code != ErrorCode.TIMEOUT) throw e
            null
        }
        if (first == null) {
            Pairing.run(c, hs, Role.SENDER, events, trust)
            return
        }
        val msg = (first as? Connection.Incoming.Control)?.message
            ?: throw ProtocolException(ErrorCode.UNEXPECTED_MESSAGE, "data during pairing")
        if (msg.type != "pair.confirm") Sessions.handleUnexpected(msg)
        if (!msg.bool("accepted")) throw ProtocolException(ErrorCode.PAIRING_REJECTED, "declined by peer", remote = true)
        if (confirmProofValid(msg, room, hs.transcriptHash)) {
            Pairing.run(c, hs, Role.SENDER, events, trust, AutoPair(false, room.expiresAtMillis), remoteAlreadyAccepted = true)
        } else {
            // The receiver confirmed without proving the room (it already trusted us): compare codes here.
            Pairing.run(c, hs, Role.SENDER, events, trust, remoteAlreadyAccepted = true)
        }
    }

    private fun confirmProofValid(msg: Message, room: Room, th: ByteArray): Boolean {
        val raw = msg.fields["room"] as? Map<*, *> ?: return false
        if (raw["id"] != room.id) return false
        val proof = (raw["proof"] as? String)?.let { runCatching { java.util.Base64.getDecoder().decode(it) }.getOrNull() } ?: return false
        return java.security.MessageDigest.isEqual(room.confirmProof(th), proof)
    }

    /**
     * Connects to the device that showed a room code, pairs through the room, and closes.
     * The device must hold the key named by the code's fingerprint. Returns the paired peer.
     */
    fun pairOnly(
        identity: IdentityKey,
        local: LocalInfo,
        trust: TrustStore,
        invite: RoomInvite,
        events: PairingEvents,
    ): PeerInfo {
        require(trust.supportsTrustExpiry) { "room pairing needs a trust store that can expire trust" }
        var lastError: ProtocolException = ProtocolException(ErrorCode.UNREACHABLE, "no address")
        for (host in invite.hosts) {
            val socket = Socket()
            try {
                socket.connect(InetSocketAddress(host, invite.port), Protocol.CONNECT_TIMEOUT_MS)
            } catch (e: IOException) {
                runCatching { socket.close() }
                lastError = ProtocolException(ErrorCode.UNREACHABLE, "connect failed")
                continue
            }
            val c = Connection(socket)
            try {
                val hs = Handshake.client(c, identity, local, trust)
                if (hs.peer.fingerprint != invite.fingerprint) throw ProtocolException(ErrorCode.AUTH_FAILED, "not the device in the room code")
                pair(c, hs, invite.room, events, trust)
                return hs.peer
            } finally {
                c.close()
            }
        }
        throw lastError
    }
}

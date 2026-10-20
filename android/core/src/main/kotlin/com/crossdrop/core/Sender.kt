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

/** A file to send. [size] may be null when the source cannot report it; it is measured while hashing. */
class OutgoingFile(
    val name: String,
    val size: Long?,
    val mime: String?,
    val open: () -> InputStream,
)

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
) {
    private val cancelled = AtomicBoolean(false)
    @Volatile private var conn: Connection? = null
    @Volatile private var encrypted = false

    init {
        require(files.isNotEmpty() && files.size <= Protocol.MAX_FILES)
    }

    fun cancel() {
        if (!cancelled.compareAndSet(false, true)) return
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
            mapIo { c.sendControl(Message.build("pair.request")) }
            Pairing.run(c, hs, Role.SENDER, events, trust)
            pairedThisSession = true
        }

        val offer = Message.build("transfer.offer", "transferId" to transferId, "files" to offerFiles.map { it.toJson() })
        events.onStage(SendStage.WAITING_FOR_ACCEPTANCE)
        mapIo { c.sendControl(offer) }
        while (true) {
            val item = c.next(Protocol.HUMAN_DECISION_TIMEOUT_MS + 5_000)
            val msg = (item as? Connection.Incoming.Control)?.message
                ?: throw ProtocolException(ErrorCode.UNEXPECTED_MESSAGE, "expected decision")
            when (msg.type) {
                "transfer.accept" -> {
                    if (msg.transferId() != transferId) throw ProtocolException(ErrorCode.BAD_MESSAGE, "wrong transferId")
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
        stream(c, offerFiles)

        // Wait for the receiver to verify the last file.
        while (true) {
            val item = c.next(Protocol.STREAM_IDLE_TIMEOUT_MS)
            val msg = (item as? Connection.Incoming.Control)?.message
                ?: throw ProtocolException(ErrorCode.UNEXPECTED_MESSAGE, "data from receiver")
            when (msg.type) {
                "transfer.progress" -> handleProgress(msg)
                "transfer.complete" -> break
                else -> Sessions.handleUnexpected(msg)
            }
        }
        trust.touch(hs.peer.deviceId, hs.peer.name)
        return hs.peer
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
        return OfferFile(index, name, total, file.mime?.takeIf { it.toByteArray().size <= 255 }, md.digest().toHex())
    }

    private fun handleProgress(msg: Message) {
        if (msg.transferId() != transferId) return
        events.onReceiverProgress(msg.long("fileId", 0, Protocol.MAX_FILES.toLong()).toInt(), msg.long("bytes", 0, Protocol.MAX_SAFE_SIZE))
    }

    private fun stream(c: Connection, offerFiles: List<OfferFile>) {
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
            var sentTotal = 0L
            for ((index, offerFile) in offerFiles.withIndex()) {
                checkCancelled()
                mapIo { c.sendControl(Message.build("transfer.start", "transferId" to transferId, "fileId" to offerFile.fileId)) }
                var sent = 0L
                try {
                    files[index].open().use { input ->
                        while (sent < offerFile.size) {
                            checkCancelled()
                            drainIncoming(c)
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
                            sentTotal += n
                            events.onBytesSent(sentTotal)
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
    private fun drainIncoming(c: Connection) {
        while (true) {
            val item = c.poll() ?: return
            val msg = (item as? Connection.Incoming.Control)?.message
                ?: throw ProtocolException(ErrorCode.UNEXPECTED_MESSAGE, "data from receiver")
            if (msg.type == "transfer.progress") handleProgress(msg) else Sessions.handleUnexpected(msg)
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

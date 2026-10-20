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

/** Where received files go. Platform-specific (MediaStore on Android, a directory on the JVM). */
interface ReceiveStorage {
    /** Free bytes at the destination, or Long.MAX_VALUE if unknown. */
    fun availableBytes(): Long

    /** Opens a temporary, not-yet-visible file for [name] (already sanitised). */
    fun begin(name: String, mime: String?, size: Long): PartialFile
}

interface PartialFile {
    val output: OutputStream

    /** Makes the verified file visible under a non-colliding name. */
    fun commit(): SavedFile

    /** Deletes the temporary file. Must not throw. */
    fun abort()
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
}

/** An accepted incoming transfer; [cancel] may be called from any thread. */
class IncomingTransfer internal constructor(
    val transferId: String,
    val peer: PeerInfo,
    val files: List<OfferFile>,
    private val conn: Connection,
) {
    val totalBytes: Long = files.sumOf { it.size }
    internal val cancelled = AtomicBoolean(false)

    fun cancel() {
        if (!cancelled.compareAndSet(false, true)) return
        runCatching { conn.sendControl(Message.build("transfer.cancel", "transferId" to transferId, "reason" to "user")) }
        conn.close()
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
) {
    private var serverSocket: ServerSocket? = null
    private var acceptThread: Thread? = null
    private val active = AtomicInteger(0)
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

        fun run() {
            try {
                runInner()
            } catch (e: ProtocolException) {
                partial?.abort()
                val t = transfer
                val error = if (t != null && t.cancelled.get()) ProtocolException(ErrorCode.CANCELLED, "cancelled") else e
                if (!error.remote && error.code != ErrorCode.CANCELLED && error.code != ErrorCode.CONNECTION_LOST && !conn.isClosed) {
                    conn.sendErrorAndClose(error.code, encrypted)
                }
                events.onFailed(t, peer, error)
            } catch (e: Exception) {
                partial?.abort()
                if (!conn.isClosed) conn.sendErrorAndClose(ErrorCode.INTERNAL, encrypted)
                events.onFailed(transfer, peer, ProtocolException(ErrorCode.INTERNAL, e.javaClass.simpleName))
            } finally {
                conn.close()
            }
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

            while (true) {
                val msg = nextControl(Protocol.STREAM_IDLE_TIMEOUT_MS)
                when (msg.type) {
                    "pair.request" -> Pairing.run(conn, hs, Role.RECEIVER, events, trust)
                    "transfer.offer" -> {
                        if (trust.get(hs.peer.deviceId) == null) {
                            mapIo { conn.sendControl(Message.build("error", "code" to ErrorCode.PAIRING_REQUIRED.wire)) }
                            continue
                        }
                        handleOffer(hs.peer, msg)
                        return
                    }
                    else -> Sessions.handleUnexpected(msg)
                }
            }
        }

        private fun nextControl(timeoutMs: Long): Message {
            val item = conn.next(timeoutMs)
            return (item as? Connection.Incoming.Control)?.message
                ?: throw ProtocolException(ErrorCode.UNEXPECTED_MESSAGE, "expected control message")
        }

        private fun reject(transferId: String, reason: String) {
            mapIo { conn.sendControl(Message.build("transfer.reject", "transferId" to transferId, "reason" to reason)) }
        }

        private fun handleOffer(peer: PeerInfo, msg: Message) {
            val transferId = msg.transferId()
            val files = OfferFile.parseOffer(msg)
            val offer = IncomingOffer(transferId, peer, files, System.currentTimeMillis() + Protocol.HUMAN_DECISION_TIMEOUT_MS)

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

            val accepted = if (trust.get(peer.deviceId)?.autoAccept == true) {
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

            mapIo { conn.sendControl(Message.build("transfer.accept", "transferId" to transferId)) }
            val t = IncomingTransfer(transferId, peer, files, conn)
            transfer = t
            events.onTransferStarted(t)
            receiveFiles(t)
            mapIo { conn.sendControl(Message.build("transfer.complete", "transferId" to transferId)) }
            trust.touch(peer.deviceId, peer.name)
            events.onCompleted(t)
            // Give the sender a moment to read `transfer.complete` and close first.
            runCatching { conn.next(2_000) }
        }

        private fun receiveFiles(t: IncomingTransfer) {
            var totalReceived = 0L
            for ((index, file) in t.files.withIndex()) {
                val start = nextControl(Protocol.STREAM_IDLE_TIMEOUT_MS)
                if (start.type != "transfer.start") Sessions.handleUnexpected(start)
                if (start.transferId() != t.transferId || start.long("fileId", 0, Protocol.MAX_FILES.toLong()).toInt() != file.fileId) {
                    throw ProtocolException(ErrorCode.BAD_MESSAGE, "files out of order")
                }

                val name = Sanitizer.fileName(file.name)
                val p = try {
                    storage.begin(name, file.mime, file.size)
                } catch (e: IOException) {
                    throw ProtocolException(ErrorCode.STORAGE_ERROR, "cannot create file")
                }
                partial = p
                val md = MessageDigest.getInstance("SHA-256")
                var received = 0L
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
                            totalReceived += item.length
                            events.onProgress(t, index, received, totalReceived)
                            val now = System.currentTimeMillis()
                            if (now - lastProgressAt >= Protocol.PROGRESS_INTERVAL_MS) {
                                lastProgressAt = now
                                sendProgress(t, file, received)
                            }
                        }
                        is Connection.Incoming.Control -> Sessions.handleUnexpected(item.message)
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
                events.onProgress(t, index, received, totalReceived)
                events.onFileSaved(t, index, saved)
            }
        }

        private fun sendProgress(t: IncomingTransfer, file: OfferFile, bytes: Long) {
            mapIo {
                conn.sendControl(Message.build("transfer.progress", "transferId" to t.transferId, "fileId" to file.fileId, "bytes" to bytes))
            }
        }
    }
}

/** Saves into a directory: temp file in the same directory, verified, then moved without overwriting. */
class DirectoryStorage(private val dir: Path) : ReceiveStorage {
    init {
        Files.createDirectories(dir)
    }

    override fun availableBytes(): Long = try {
        Files.getFileStore(dir).usableSpace
    } catch (e: IOException) {
        Long.MAX_VALUE
    }

    override fun begin(name: String, mime: String?, size: Long): PartialFile {
        val temp = dir.resolve(".crossdrop-${UUID.randomUUID()}.partial")
        val out = Files.newOutputStream(temp, java.nio.file.StandardOpenOption.CREATE_NEW, java.nio.file.StandardOpenOption.WRITE)
        return object : PartialFile {
            override val output: OutputStream = out.buffered(256 * 1024)

            override fun commit(): SavedFile {
                var n = 0
                while (true) {
                    val candidate = if (n == 0) name else Sanitizer.numbered(name, n)
                    val target = dir.resolve(candidate)
                    if (target.parent != dir) throw IOException("escapes destination")
                    try {
                        if (Files.exists(target, java.nio.file.LinkOption.NOFOLLOW_LINKS)) throw FileAlreadyExistsException(candidate)
                        Files.move(temp, target, StandardCopyOption.ATOMIC_MOVE)
                        // ATOMIC_MOVE may replace on some platforms; the existence check above guards the common case.
                        return SavedFile(candidate, target.toAbsolutePath().toString())
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
        }
    }
}

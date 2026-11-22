package com.crossdrop.core

import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Turbo (§9.10): a multi-file transfer spread over up to [Protocol.MAX_TURBO_STREAMS]
 * connections. The main connection carries offer / accept / complete; extra connections
 * join with a one-time token and carry whole files, each announced by `transfer.start`.
 */
internal object Turbo {
    private val random = SecureRandom()

    fun newToken(): String {
        val bytes = ByteArray(16).also(random::nextBytes)
        return java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }

    /** Parses `join` from `transfer.accept` when the offer asked for [requested] streams; null when absent. */
    fun parseJoin(msg: Message, requested: Int?): Join? {
        val raw = msg.fields["join"] ?: return null
        // A sender that did not ask for Turbo ignores the field (§9.10).
        if (requested == null) return null
        @Suppress("UNCHECKED_CAST")
        val m = Message(((raw as? Map<String, Any?>) ?: throw ProtocolException(ErrorCode.BAD_MESSAGE, "bad join")) + mapOf("type" to "join", "v" to 1L))
        val token = m.string("token", 64)
        if (!Protocol.isValidJoinToken(token)) throw ProtocolException(ErrorCode.BAD_MESSAGE, "bad join token")
        val max = m.long("max", 2, requested.toLong()).toInt()
        return Join(token, max)
    }

    class Join(val token: String, val max: Int)

    /** Woken on the main connection when the group finished or failed. */
    object Wake
}

/** Receiver side: the transfers that currently accept joins, by transferId. */
internal class TurboRegistry {
    private val groups = ConcurrentHashMap<String, IncomingTurbo>()

    /** False when another transfer already uses this id (that offer then gets no `join`). */
    fun register(group: IncomingTurbo): Boolean = groups.putIfAbsent(group.transferId, group) == null

    fun find(transferId: String): IncomingTurbo? = groups[transferId]

    fun remove(group: IncomingTurbo) {
        groups.remove(group.transferId, group)
    }
}

/**
 * Receiver-side state shared by the connections of one Turbo transfer. Files may arrive
 * on any connection in any order; each is claimed once. The main session sends
 * `transfer.complete` when every file is verified. Any failure ends every connection.
 */
internal class IncomingTurbo(
    val transferId: String,
    val peerDeviceId: String,
    val token: String,
    val maxStreams: Int,
    val files: List<OfferFile>,
    val resumeAt: Map<Int, Long>,
    val main: Connection,
    private val registry: TurboRegistry,
) {
    lateinit var transfer: IncomingTransfer
    private val lock = Any()
    private val sides = ArrayList<Connection>()
    private val claimed = HashSet<Int>()
    private var done = 0
    private var joinedCount = 0
    @Volatile var error: ProtocolException? = null
        private set
    /** Completed or failed: no more joins, files or failures. */
    @Volatile var finished = false
        private set
    @Volatile var lastActivity = System.currentTimeMillis()

    val allDone: Boolean get() = synchronized(lock) { done == files.size }

    /** Connections that took part, the main one included. */
    val streams: Int get() = synchronized(lock) { 1 + joinedCount }

    fun touch() {
        lastActivity = System.currentTimeMillis()
    }

    /** Adds a side connection. Returns null on success, else the error code to refuse it with. */
    fun join(conn: Connection, deviceId: String, presented: String): ErrorCode? = synchronized(lock) {
        if (finished || deviceId != peerDeviceId) return ErrorCode.UNEXPECTED_MESSAGE
        val ok = MessageDigest.isEqual(presented.toByteArray(Charsets.UTF_8), token.toByteArray(Charsets.UTF_8))
        if (!ok) return ErrorCode.AUTH_FAILED
        if (1 + joinedCount >= maxStreams) return ErrorCode.BUSY
        sides.add(conn)
        joinedCount++
        touch()
        null
    }

    /** Claims [fileId] for the calling connection; its index in the offer. */
    fun claim(fileId: Int): Int = synchronized(lock) {
        if (finished) throw ProtocolException(ErrorCode.CONNECTION_LOST, "transfer ended")
        val index = files.indexOfFirst { it.fileId == fileId }
        if (index < 0 || !claimed.add(fileId)) throw ProtocolException(ErrorCode.BAD_MESSAGE, "file already sent or unknown")
        index
    }

    /** A claimed file was verified and saved; wakes the main session after the last one. */
    fun fileDone() {
        val last = synchronized(lock) {
            done++
            done == files.size
        }
        if (last && !main.tryInject(Turbo.Wake)) {
            // The main session also re-checks every few seconds; nothing is lost.
        }
    }

    /**
     * Every file is verified and `transfer.complete` went out: wakes the side sessions, which
     * give the sender a moment to close each connection first (it does once it read the complete).
     */
    fun complete() {
        val open = synchronized(lock) {
            if (finished) return
            finished = true
            ArrayList(sides)
        }
        registry.remove(this)
        for (c in open) if (!c.tryInject(Turbo.Wake)) c.close()
    }

    /**
     * Records the first failure and ends every other connection, telling the sender why
     * when it is our own error. Returns false when the group had already finished.
     */
    fun fail(e: ProtocolException, origin: Connection?): Boolean {
        val others = synchronized(lock) {
            if (finished) return false
            finished = true
            error = e
            (sides + main).filter { it !== origin }
        }
        registry.remove(this)
        for (c in others) {
            when {
                e.remote || e.code == ErrorCode.CONNECTION_LOST || e.code == ErrorCode.TIMEOUT -> c.close()
                e.code == ErrorCode.CANCELLED -> {
                    runCatching { c.sendControl(Message.build("transfer.cancel", "transferId" to transferId, "reason" to "user")) }
                    c.close()
                }
                else -> c.sendErrorAndClose(e.code, true)
            }
        }
        return true
    }

    fun closeSides() {
        val open = synchronized(lock) { ArrayList(sides) }
        open.forEach { it.close() }
    }
}

/**
 * Sender-side state of one Turbo transfer: the queue of files still to send and every
 * connection in use. Each connection takes the next file when it is free.
 */
internal class OutgoingTurbo(val main: Connection, fileCount: Int, sideAttempts: Int) {
    private val queue = ConcurrentLinkedQueue<Int>((0 until fileCount).toList())
    val sides = CopyOnWriteArrayList<Connection>()
    private val failed = AtomicBoolean(false)
    @Volatile var error: ProtocolException? = null
        private set
    /** Completed or failed. */
    @Volatile var ended = false
    private val joined = AtomicInteger(0)
    private val settled = CountDownLatch(sideAttempts)
    @Volatile var lastActivity = System.currentTimeMillis()
    val sent = AtomicLong(0)

    val streams: Int get() = 1 + joined.get()

    fun next(): Int? = if (ended) null else queue.poll()

    fun touch() {
        lastActivity = System.currentTimeMillis()
    }

    /** False when the transfer already ended (the caller closes [c]). */
    fun addSide(c: Connection): Boolean {
        sides.add(c)
        if (ended) {
            sides.remove(c)
            return false
        }
        return true
    }

    /** Connections that sent `transfer.join` and got `transfer.joined`. */
    private val joinedSides = java.util.concurrent.CopyOnWriteArraySet<Connection>()

    /** [c] joined the transfer: only joined connections are told about a cancel. */
    fun joined(c: Connection) {
        joinedSides.add(c)
        joined.incrementAndGet()
    }

    fun hasJoined(c: Connection): Boolean = joinedSides.contains(c)

    /** One extra connection finished trying to join, whatever the outcome. */
    fun settle() = settled.countDown()

    fun awaitSettled(ms: Long) {
        settled.await(ms, java.util.concurrent.TimeUnit.MILLISECONDS)
    }

    /**
     * Records the first failure, closes the extra connections and (from another thread)
     * wakes the main thread, which reports it. False when a failure was already recorded.
     */
    fun fail(e: ProtocolException, wakeMain: Boolean = true): Boolean {
        if (!failed.compareAndSet(false, true)) return false
        error = e
        ended = true
        sides.forEach { it.close() }
        if (wakeMain && !main.tryInject(Turbo.Wake)) main.close()
        return true
    }

    fun closeSides() {
        ended = true
        sides.forEach { it.close() }
    }
}

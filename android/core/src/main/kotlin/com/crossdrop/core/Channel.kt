package com.crossdrop.core

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * One TCP connection: plaintext frames during the handshake (§3.1), then
 * encrypted records (§3.2) read by a dedicated reader thread into a small
 * bounded queue. The bound gives natural backpressure: when the consumer
 * stops draining, the reader stops reading and TCP flow control pushes back
 * on the peer.
 */
class Connection(val socket: Socket) {
    private val input = DataInputStream(BufferedInputStream(socket.getInputStream(), 64 * 1024))
    private val output = BufferedOutputStream(socket.getOutputStream(), 64 * 1024)
    private val writeLock = Any()
    private val closed = AtomicBoolean(false)

    private var sendCipher: RecordCipher? = null
    private var recvCipher: RecordCipher? = null
    private val sealBuffer = ByteArray(4 + Protocol.MAX_ENCRYPTED_FRAME)
    private val plainBuffer = ByteArray(1 + Protocol.MAX_DATA_BODY)

    private val queue = LinkedBlockingQueue<Incoming>(4)
    private var reader: Thread? = null

    /** Monotonic time of the last successful socket write (used by the stall watchdog). */
    @Volatile
    var lastWriteAt: Long = System.nanoTime()
        private set

    init {
        socket.tcpNoDelay = true
        socket.keepAlive = true
    }

    // ---- plaintext phase ----

    fun writePlain(payload: ByteArray) {
        require(payload.size in 1..Protocol.MAX_PLAINTEXT_FRAME)
        synchronized(writeLock) {
            writeU32(payload.size)
            output.write(payload)
            output.flush()
        }
    }

    fun writePlain(message: Map<String, Any?>) = writePlain(Json.encode(message))

    /** Reads one plaintext frame with the given timeout. */
    fun readPlain(timeoutMs: Int = Protocol.HANDSHAKE_STEP_TIMEOUT_MS): ByteArray {
        socket.soTimeout = timeoutMs
        try {
            val len = readLength(Protocol.MAX_PLAINTEXT_FRAME)
            val buf = ByteArray(len)
            input.readFully(buf)
            return buf
        } catch (e: SocketTimeoutException) {
            throw ProtocolException(ErrorCode.TIMEOUT, "handshake timed out")
        } catch (e: EOFException) {
            throw ProtocolException(ErrorCode.CONNECTION_LOST, "peer closed during handshake")
        }
    }

    // ---- encrypted phase ----

    /** Switches to encrypted records and starts the reader thread. */
    fun startEncrypted(sendKey: ByteArray, recvKey: ByteArray, threadName: String) {
        sendCipher = RecordCipher(sendKey, encrypt = true)
        recvCipher = RecordCipher(recvKey, encrypt = false)
        socket.soTimeout = 0 // timeouts are enforced by queue polling instead
        reader = Thread({ readLoop() }, threadName).apply {
            isDaemon = true
            start()
        }
    }

    fun sendControl(message: Map<String, Any?>) {
        val body = Json.encode(message)
        if (body.size > Protocol.MAX_CONTROL_BODY) throw ProtocolException(ErrorCode.INTERNAL, "control message too large")
        synchronized(writeLock) {
            plainBuffer[0] = Protocol.KIND_CONTROL
            body.copyInto(plainBuffer, 1)
            sealAndWrite(1 + body.size)
        }
    }

    fun sendData(buf: ByteArray, off: Int, len: Int) {
        require(len in 1..Protocol.MAX_DATA_BODY)
        synchronized(writeLock) {
            plainBuffer[0] = Protocol.KIND_DATA
            System.arraycopy(buf, off, plainBuffer, 1, len)
            sealAndWrite(1 + len)
        }
    }

    private fun sealAndWrite(plainLen: Int) {
        val cipher = sendCipher ?: throw IllegalStateException("not encrypted yet")
        val n = cipher.seal(plainBuffer, 0, plainLen, sealBuffer, 4)
        sealBuffer[0] = (n ushr 24).toByte()
        sealBuffer[1] = (n ushr 16).toByte()
        sealBuffer[2] = (n ushr 8).toByte()
        sealBuffer[3] = n.toByte()
        output.write(sealBuffer, 0, 4 + n)
        output.flush()
        lastWriteAt = System.nanoTime()
    }

    /**
     * Next incoming record, waiting at most [timeoutMs]. Throws [ProtocolException]
     * for timeouts, connection loss and protocol violations.
     */
    fun next(timeoutMs: Long): Incoming {
        val item = queue.poll(timeoutMs, TimeUnit.MILLISECONDS)
            ?: throw ProtocolException(ErrorCode.TIMEOUT, "no data from peer")
        if (item is Incoming.Failure) {
            // Keep the failure visible to any later caller too.
            queue.offer(item)
            throw item.error
        }
        return item
    }

    /** Non-blocking variant: null when nothing is waiting. */
    fun poll(): Incoming? {
        val item = queue.poll() ?: return null
        if (item is Incoming.Failure) {
            queue.offer(item)
            throw item.error
        }
        return item
    }

    private fun readLoop() {
        try {
            while (!closed.get()) {
                val len = readLength(Protocol.MAX_ENCRYPTED_FRAME)
                val payload = ByteArray(len)
                input.readFully(payload)
                val plain = recvCipher!!.open(payload)
                if (plain.isEmpty()) throw ProtocolException(ErrorCode.BAD_FRAME, "empty record")
                val item = when (plain[0]) {
                    Protocol.KIND_CONTROL -> {
                        if (plain.size - 1 > Protocol.MAX_CONTROL_BODY) throw ProtocolException(ErrorCode.FRAME_TOO_LARGE)
                        Incoming.Control(Message.parse(plain.copyOfRange(1, plain.size)))
                    }
                    Protocol.KIND_DATA -> {
                        if (plain.size < 2) throw ProtocolException(ErrorCode.BAD_FRAME, "empty data record")
                        Incoming.Data(plain, 1, plain.size - 1)
                    }
                    else -> throw ProtocolException(ErrorCode.BAD_FRAME, "unknown record kind")
                }
                queue.put(item)
            }
        } catch (e: ProtocolException) {
            fail(e)
        } catch (e: IOException) {
            fail(ProtocolException(ErrorCode.CONNECTION_LOST, if (closed.get()) "closed" else "connection lost"))
        } catch (e: InterruptedException) {
            fail(ProtocolException(ErrorCode.CONNECTION_LOST, "interrupted"))
        }
    }

    private fun fail(e: ProtocolException) {
        // Drop anything unconsumed so the failure is seen promptly.
        if (e.code != ErrorCode.CONNECTION_LOST) queue.clear()
        while (!queue.offer(Incoming.Failure(e))) queue.poll()
    }

    /** Best-effort error frame, then close. Never throws. */
    fun sendErrorAndClose(code: ErrorCode, encrypted: Boolean) {
        try {
            val msg = Message.build("error", "code" to code.wire)
            if (encrypted) sendControl(msg) else writePlain(msg)
        } catch (_: Exception) {
        }
        close()
    }

    fun close() {
        if (closed.compareAndSet(false, true)) {
            try {
                socket.close()
            } catch (_: IOException) {
            }
        }
    }

    val isClosed: Boolean get() = closed.get()

    private fun readLength(max: Int): Int {
        val len = input.readInt()
        if (len == 0) throw ProtocolException(ErrorCode.BAD_FRAME, "zero-length frame")
        if (len < 0 || len > max) throw ProtocolException(ErrorCode.FRAME_TOO_LARGE)
        return len
    }

    private fun writeU32(v: Int) {
        output.write(v ushr 24)
        output.write(v ushr 16)
        output.write(v ushr 8)
        output.write(v)
    }

    sealed class Incoming {
        class Control(val message: Message) : Incoming()

        /** File bytes at [offset, offset+length) of [buffer]. */
        class Data(val buffer: ByteArray, val offset: Int, val length: Int) : Incoming()

        class Failure(val error: ProtocolException) : Incoming()

        /** A local event (user decision) injected so one wait covers both peer and user. */
        class Local(val value: Any) : Incoming()
    }

    /** Wakes a waiter in [next] with a local event. */
    fun inject(value: Any) {
        queue.offer(Incoming.Local(value), 1, TimeUnit.SECONDS)
    }
}

/** Converts I/O failures to protocol errors for uniform handling. */
internal inline fun <T> mapIo(block: () -> T): T = try {
    block()
} catch (e: SocketTimeoutException) {
    throw ProtocolException(ErrorCode.TIMEOUT)
} catch (e: IOException) {
    throw ProtocolException(ErrorCode.CONNECTION_LOST, "connection lost")
}

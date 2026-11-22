package com.crossdrop.engine

data class FileModel(val name: String, val size: Long, val mime: String?, val bytes: Long = 0, val uri: String? = null)

/** Mutable transfer state, only touched under the engine lock. */
class TransferModel(
    val id: String,
    val direction: String,
    val peerId: String,
    var peerName: String,
    val peerPlatform: String,
    val files: MutableList<FileModel>,
) {
    var status: String = "connecting"
    var bytesTransferred: Long = 0
    val startedAt: Long = System.currentTimeMillis()
    var updatedAt: Long = startedAt
    var error: String? = null
    var rejectReason: String? = null
    var canRetry: Boolean = false
    val rate = RateMeter()
    /** "files", or "link" / "text" for a handoff that is not saved as a file (§9.2). */
    var kind: String = "files"
    /** The received (or sent) link / text, kept in memory only for this app session. */
    var text: String? = null
    /** Expiring drop (§9.8): seconds after which the sender asked for deletion. */
    var expiresAfter: Long? = null
    /** Incoming expiring drop: when CrossDrop deletes the saved files. */
    var deleteAt: Long? = null
    /** Set when this transfer delivers a "send when nearby" queue item. */
    var queueId: String? = null
    /** Set when this transfer answers a capture request (§9.7). */
    var captureRequestId: String? = null
    /** The address the (current attempt of the) outgoing transfer connects to. */
    var targetHost: String? = null
    /** Connections used: more than 1 with Turbo (§9.10). */
    var streams: Int = 1
    /** Last 10% step that produced a haptic tick. */
    var lastDecile: Int = 0

    val totalBytes: Long get() = files.sumOf { it.size }
    val isFinished: Boolean get() = status in FINISHED

    companion object {
        val FINISHED = setOf("completed", "failed", "cancelled", "rejected")
    }
}

/**
 * Smoothed throughput. Reports null until at least a second of data exists so
 * the UI never shows a wild first estimate.
 */
class RateMeter {
    private var startAt = 0L
    private var lastAt = 0L
    private var lastBytes = 0L
    private var value: Double? = null

    @Synchronized
    fun reset() {
        startAt = 0
        value = null
    }

    @Synchronized
    fun sample(totalBytes: Long) {
        val now = System.nanoTime()
        if (startAt == 0L) {
            startAt = now
            lastAt = now
            lastBytes = totalBytes
            return
        }
        val dt = (now - lastAt) / 1e9
        if (dt < 0.5) return
        val instant = (totalBytes - lastBytes) / dt
        value = value?.let { 0.7 * it + 0.3 * instant } ?: instant
        lastAt = now
        lastBytes = totalBytes
    }

    @Synchronized
    fun bytesPerSecond(): Double? = if (startAt != 0L && (System.nanoTime() - startAt) >= 1_000_000_000L) value else null
}

package com.crossdrop.queue

import android.content.Context
import android.net.Uri
import com.crossdrop.core.Json
import com.crossdrop.share.SharedFile
import java.io.File
import java.io.IOException
import java.util.UUID

/** One file of a queued send. [copied]: CrossDrop keeps its own copy because the source grant would not last. */
data class QueuedFile(
    val uri: String,
    val name: String,
    val size: Long?,
    val mime: String?,
    val path: List<String>,
    val copied: Boolean,
) {
    fun toShared() = SharedFile(uri, name, size, mime, path)
}

/**
 * "Send when nearby": a send to a paired device that wasn't reachable when the user
 * asked. [status] is "waiting" (until the device shows up), "sending" (a transfer is
 * running: [transferId]) or "failed" ([error]; the user can retry or cancel).
 */
data class QueuedSend(
    val id: String,
    val deviceId: String,
    /** "files", "link" or "text". */
    val kind: String,
    val files: List<QueuedFile>,
    /** The link or text for kind link / text. Kept only in private app storage. */
    val text: String?,
    val createdAt: Long,
    /** Expiring drop (§9.8) requested by the user, in seconds. */
    val expiresAfter: Long?,
    val status: String = "waiting",
    val error: String? = null,
    val attempts: Int = 0,
    val transferId: String? = null,
    val lastTriedAt: Long? = null,
) {
    val totalBytes: Long get() = files.sumOf { it.size ?: 0 }
}

/** The queue is over its size or item limit; nothing was added. */
class QueueFullException(message: String) : IOException(message)

/**
 * Persistent "send when nearby" queue, stored as JSON in private app storage
 * (files dir, never backed up: allowBackup is off). Files the user picked with a
 * lasting read grant are referenced; anything else (share-sheet items whose grant
 * ends with the activity) is copied into private storage, up to [LIMIT_BYTES] in
 * total, and deleted as soon as the item is sent or cancelled.
 */
class SendQueue(private val context: Context) {
    private val file = File(context.filesDir, "send-queue.json")
    private val copies = File(context.filesDir, "queue")
    private val items = ArrayList<QueuedSend>()

    init {
        runCatching { load() }
        // Anything marked "sending" when the process died is waiting again.
        for (i in items.indices) if (items[i].status == "sending") items[i] = items[i].copy(status = "waiting", transferId = null)
        // Copies whose item is gone (crash between steps) are removed.
        copies.listFiles()?.forEach { dir -> if (items.none { it.id == dir.name }) dir.deleteRecursively() }
    }

    @Synchronized
    fun all(): List<QueuedSend> = items.toList()

    @Synchronized
    fun get(id: String): QueuedSend? = items.firstOrNull { it.id == id }

    @Synchronized
    fun waitingFor(deviceId: String): List<QueuedSend> = items.filter { it.deviceId == deviceId && it.status == "waiting" }

    @Synchronized
    fun waitingDevices(): Set<String> = items.filter { it.status == "waiting" }.map { it.deviceId }.toSet()

    /** Bytes held in CrossDrop's own copies. */
    @Synchronized
    fun usedBytes(): Long = items.sumOf { q -> q.files.filter { it.copied }.sumOf { it.size ?: 0 } }

    /**
     * Queues [files] for [deviceId], copying those without a lasting grant. Blocking
     * (copies can be large); call off the main thread. Throws [QueueFullException].
     */
    fun addFiles(deviceId: String, files: List<SharedFile>, expiresAfter: Long?): QueuedSend {
        require(files.isNotEmpty()) { "no files" }
        checkCount()
        val id = UUID.randomUUID().toString()
        val dir = File(copies, id)
        try {
            var budget = LIMIT_BYTES - usedBytes()
            val queued = files.mapIndexed { index, f ->
                if (hasLastingGrant(f.uri)) {
                    QueuedFile(f.uri, f.name, f.size, f.mime, f.path, copied = false)
                } else {
                    if (f.size != null && f.size > budget) throw QueueFullException("queue_full")
                    dir.mkdirs()
                    val target = File(dir, index.toString())
                    val written = copy(Uri.parse(f.uri), target, budget)
                    budget -= written
                    QueuedFile(Uri.fromFile(target).toString(), f.name, written, f.mime, f.path, copied = true)
                }
            }
            val item = QueuedSend(id, deviceId, "files", queued, null, System.currentTimeMillis(), expiresAfter)
            synchronized(this) {
                items.add(item)
                persist()
            }
            return item
        } catch (e: Exception) {
            dir.deleteRecursively()
            throw e
        }
    }

    /** Queues a link or text (§9.2). */
    fun addText(deviceId: String, kind: String, text: String): QueuedSend {
        require(kind == "link" || kind == "text")
        checkCount()
        val item = QueuedSend(UUID.randomUUID().toString(), deviceId, kind, emptyList(), text, System.currentTimeMillis(), null)
        synchronized(this) {
            items.add(item)
            persist()
        }
        return item
    }

    /** Marks a waiting item as sending; null when it is not waiting (someone else took it, or it was cancelled). */
    @Synchronized
    fun claim(id: String): QueuedSend? {
        val i = items.indexOfFirst { it.id == id }
        if (i < 0 || items[i].status != "waiting") return null
        items[i] = items[i].copy(status = "sending", attempts = items[i].attempts + 1, lastTriedAt = System.currentTimeMillis(), error = null)
        persist()
        return items[i]
    }

    @Synchronized
    fun update(id: String, transform: (QueuedSend) -> QueuedSend): QueuedSend? {
        val i = items.indexOfFirst { it.id == id }
        if (i < 0) return null
        items[i] = transform(items[i])
        persist()
        return items[i]
    }

    /** Removes the item and CrossDrop's copies of its files. Picked originals are never touched. */
    fun remove(id: String) {
        synchronized(this) {
            if (!items.removeAll { it.id == id }) return
            persist()
        }
        File(copies, id).deleteRecursively()
    }

    private fun checkCount() {
        if (synchronized(this) { items.size } >= MAX_ITEMS) throw QueueFullException("queue_full")
    }

    /** True when CrossDrop holds a persisted read grant for [uri] (directly or through a picked folder). */
    private fun hasLastingGrant(uri: String): Boolean {
        val u = Uri.parse(uri)
        if (u.scheme != "content") return false
        return context.contentResolver.persistedUriPermissions.any { p ->
            p.isReadPermission && (p.uri == u || uri.startsWith(p.uri.toString() + "/document/"))
        }
    }

    /** Streams [source] into [target], failing once more than [budget] bytes would be needed. */
    private fun copy(source: Uri, target: File, budget: Long): Long {
        val input = context.contentResolver.openInputStream(source) ?: throw IOException("unreadable")
        var total = 0L
        input.use { inp ->
            target.outputStream().use { out ->
                val buf = ByteArray(256 * 1024)
                while (true) {
                    val n = inp.read(buf)
                    if (n < 0) break
                    total += n
                    if (total > budget) throw QueueFullException("queue_full")
                    out.write(buf, 0, n)
                }
            }
        }
        return total
    }

    private fun persist() {
        val json = Json.write(items.map { q ->
            linkedMapOf(
                "id" to q.id,
                "deviceId" to q.deviceId,
                "kind" to q.kind,
                "files" to q.files.map {
                    linkedMapOf(
                        "uri" to it.uri, "name" to it.name, "size" to it.size, "mime" to it.mime,
                        "path" to it.path.joinToString("/"), "copied" to it.copied,
                    )
                },
                "text" to q.text,
                "createdAt" to q.createdAt,
                "expiresAfter" to q.expiresAfter,
                "status" to q.status,
                "error" to q.error,
                "attempts" to q.attempts,
                "lastTriedAt" to q.lastTriedAt,
            )
        })
        val tmp = File(file.parentFile, "send-queue.json.tmp")
        tmp.writeText(json)
        tmp.renameTo(file)
    }

    @Suppress("UNCHECKED_CAST")
    private fun load() {
        if (!file.exists()) return
        val list = Json.parse(file.readText()) as List<Map<String, Any?>>
        for (m in list) {
            runCatching {
                items.add(
                    QueuedSend(
                        id = m["id"] as String,
                        deviceId = m["deviceId"] as String,
                        kind = m["kind"] as String,
                        files = (m["files"] as List<Map<String, Any?>>).map {
                            QueuedFile(
                                it["uri"] as String,
                                it["name"] as String,
                                (it["size"] as? Number)?.toLong(),
                                it["mime"] as String?,
                                (it["path"] as? String)?.split('/')?.filter { p -> p.isNotBlank() } ?: emptyList(),
                                it["copied"] as? Boolean ?: false,
                            )
                        },
                        text = m["text"] as String?,
                        createdAt = (m["createdAt"] as Number).toLong(),
                        expiresAfter = (m["expiresAfter"] as? Number)?.toLong(),
                        status = m["status"] as? String ?: "waiting",
                        error = m["error"] as String?,
                        attempts = (m["attempts"] as? Number)?.toInt() ?: 0,
                        lastTriedAt = (m["lastTriedAt"] as? Number)?.toLong(),
                    ),
                )
            }
        }
    }

    companion object {
        /** CrossDrop's own copies of queued share-sheet files, all items together. */
        const val LIMIT_BYTES = 512L * 1024 * 1024
        const val MAX_ITEMS = 50
    }
}

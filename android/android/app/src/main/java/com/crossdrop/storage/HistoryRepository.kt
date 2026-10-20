package com.crossdrop.storage

import android.content.Context
import com.crossdrop.core.Json
import java.io.File

/** A finished transfer, kept only on this device. */
data class HistoryEntry(
    val id: String,
    val direction: String,
    val peerName: String,
    val peerPlatform: String,
    val status: String,
    val files: List<HistoryFile>,
    val totalBytes: Long,
    val finishedAt: Long,
    val errorCode: String?,
)

data class HistoryFile(val name: String, val size: Long, val uri: String?)

/** Local transfer history (newest first, capped). Stored as JSON in private app storage. */
class HistoryRepository(context: Context) {
    private val file = File(context.filesDir, "history.json")
    private val entries = ArrayList<HistoryEntry>()

    init {
        runCatching { load() }
    }

    @Synchronized
    fun all(): List<HistoryEntry> = entries.toList()

    @Synchronized
    fun add(entry: HistoryEntry) {
        entries.removeAll { it.id == entry.id }
        entries.add(0, entry)
        while (entries.size > MAX) entries.removeAt(entries.size - 1)
        persist()
    }

    @Synchronized
    fun clear() {
        entries.clear()
        persist()
    }

    private fun persist() {
        val json = Json.write(entries.map { e ->
            linkedMapOf(
                "id" to e.id,
                "direction" to e.direction,
                "peerName" to e.peerName,
                "peerPlatform" to e.peerPlatform,
                "status" to e.status,
                "files" to e.files.map { linkedMapOf("name" to it.name, "size" to it.size, "uri" to it.uri) },
                "totalBytes" to e.totalBytes,
                "finishedAt" to e.finishedAt,
                "errorCode" to e.errorCode,
            )
        })
        val tmp = File(file.parentFile, "history.json.tmp")
        tmp.writeText(json)
        tmp.renameTo(file)
    }

    @Suppress("UNCHECKED_CAST")
    private fun load() {
        if (!file.exists()) return
        val list = Json.parse(file.readText()) as List<Map<String, Any?>>
        for (m in list) {
            entries.add(
                HistoryEntry(
                    id = m["id"] as String,
                    direction = m["direction"] as String,
                    peerName = m["peerName"] as String,
                    peerPlatform = m["peerPlatform"] as String,
                    status = m["status"] as String,
                    files = (m["files"] as List<Map<String, Any?>>).map {
                        HistoryFile(it["name"] as String, it["size"] as Long, it["uri"] as String?)
                    },
                    totalBytes = m["totalBytes"] as Long,
                    finishedAt = m["finishedAt"] as Long,
                    errorCode = m["errorCode"] as String?,
                ),
            )
        }
    }

    companion object {
        const val MAX = 200
    }
}

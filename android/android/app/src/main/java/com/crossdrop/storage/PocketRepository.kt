package com.crossdrop.storage

import android.content.Context
import com.crossdrop.core.Json
import java.io.File

/** A received file in the Pocket (recent arrivals), kept only on this device. */
data class PocketItem(
    val id: String,
    /** Content URI of the saved file. */
    val uri: String,
    val name: String,
    val size: Long,
    val mime: String?,
    val receivedAt: Long,
    val from: String,
    val fromPlatform: String,
    /** Expiring drop (§9.8): when CrossDrop deletes the file. */
    val deleteAt: Long? = null,
)

/**
 * Pocket: the last [MAX] received files, newest first. Removing an item from the
 * Pocket never deletes the file unless the caller asks for that separately.
 * Stored as JSON in private app storage.
 */
class PocketRepository(context: Context) {
    private val file = File(context.filesDir, "pocket.json")
    private val items = ArrayList<PocketItem>()

    init {
        runCatching { load() }
    }

    /** Items whose expiring-drop time has not passed. */
    @Synchronized
    fun all(): List<PocketItem> {
        val now = System.currentTimeMillis()
        return items.filter { it.deleteAt == null || it.deleteAt > now }
    }

    @Synchronized
    fun get(id: String): PocketItem? = items.firstOrNull { it.id == id }

    @Synchronized
    fun add(newItems: List<PocketItem>) {
        if (newItems.isEmpty()) return
        items.removeAll { old -> newItems.any { it.id == old.id || it.uri == old.uri } }
        items.addAll(0, newItems)
        while (items.size > MAX) items.removeAt(items.size - 1)
        persist()
    }

    @Synchronized
    fun remove(id: String): PocketItem? {
        val item = items.firstOrNull { it.id == id } ?: return null
        items.remove(item)
        persist()
        return item
    }

    /** Drops items for files that no longer exist (deleted expiring drops). */
    @Synchronized
    fun removeUris(uris: Collection<String>) {
        if (uris.isEmpty()) return
        if (items.removeAll { it.uri in uris }) persist()
    }

    private fun persist() {
        val json = Json.write(items.map {
            linkedMapOf(
                "id" to it.id,
                "uri" to it.uri,
                "name" to it.name,
                "size" to it.size,
                "mime" to it.mime,
                "receivedAt" to it.receivedAt,
                "from" to it.from,
                "fromPlatform" to it.fromPlatform,
                "deleteAt" to it.deleteAt,
            )
        })
        val tmp = File(file.parentFile, "pocket.json.tmp")
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
                    PocketItem(
                        id = m["id"] as String,
                        uri = m["uri"] as String,
                        name = m["name"] as String,
                        size = (m["size"] as Number).toLong(),
                        mime = m["mime"] as String?,
                        receivedAt = (m["receivedAt"] as Number).toLong(),
                        from = m["from"] as String,
                        fromPlatform = m["fromPlatform"] as String,
                        deleteAt = (m["deleteAt"] as? Number)?.toLong(),
                    ),
                )
            }
        }
    }

    companion object {
        const val MAX = 30
    }
}

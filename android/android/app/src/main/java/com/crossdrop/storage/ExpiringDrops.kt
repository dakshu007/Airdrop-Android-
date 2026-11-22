package com.crossdrop.storage

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.crossdrop.core.Json
import com.crossdrop.engine.Engine
import java.io.File

/**
 * Expiring drops (§9.8), receiver side: files a sender asked to have deleted after a
 * while. CrossDrop records each saved item with its delete time and removes its own
 * MediaStore items when due: at app start, when the service starts, and from an
 * inexact alarm (no exact-alarm permission; it may run somewhat late, never early).
 *
 * This is a courtesy, not a guarantee: the user could copy or share the file first,
 * and an item CrossDrop no longer owns (e.g. after a reinstall) cannot be deleted.
 */
class ExpiringDrops private constructor(private val context: Context) {
    private class Entry(val uri: String, val deleteAt: Long, val transferId: String)

    private val file = File(context.filesDir, "expiring.json")
    private val entries = ArrayList<Entry>()

    init {
        runCatching { load() }
    }

    @Synchronized
    fun add(transferId: String, uris: List<String>, deleteAt: Long) {
        if (uris.isEmpty()) return
        uris.forEach { entries.add(Entry(it, deleteAt, transferId)) }
        persist()
        schedule()
    }

    @Synchronized
    fun isEmpty(): Boolean = entries.isEmpty()

    /** Deletes every item that is due. Returns the URIs that are gone (deleted, or no longer ours). */
    fun purgeDue(): List<String> {
        val due = synchronized(this) {
            val now = System.currentTimeMillis()
            entries.filter { it.deleteAt <= now }
        }
        if (due.isEmpty()) {
            schedule()
            return emptyList()
        }
        // Deleting talks to MediaStore; done outside the lock. A failed delete (not ours
        // any more, or already gone) is not retried forever.
        due.forEach { MediaStoreStorage.delete(context, it.uri) }
        synchronized(this) {
            entries.removeAll { e -> due.any { it.uri == e.uri && it.deleteAt == e.deleteAt } }
            persist()
        }
        schedule()
        return due.map { it.uri }
    }

    /** Sets (or clears) the inexact alarm for the next due item. */
    fun schedule() {
        val next = synchronized(this) { entries.minOfOrNull { it.deleteAt } }
        val am = context.getSystemService(AlarmManager::class.java) ?: return
        val pi = PendingIntent.getBroadcast(
            context, 0, Intent(context, ExpiryReceiver::class.java).setAction(ACTION),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        if (next == null) {
            am.cancel(pi)
            return
        }
        // Not a wakeup alarm: deleting a little late is fine, waking the phone for it is not.
        runCatching { am.set(AlarmManager.RTC, next.coerceAtLeast(System.currentTimeMillis() + 60_000), pi) }
    }

    private fun persist() {
        val json = Json.write(entries.map { linkedMapOf("uri" to it.uri, "deleteAt" to it.deleteAt, "transferId" to it.transferId) })
        val tmp = File(file.parentFile, "expiring.json.tmp")
        tmp.writeText(json)
        tmp.renameTo(file)
    }

    @Suppress("UNCHECKED_CAST")
    private fun load() {
        if (!file.exists()) return
        val list = Json.parse(file.readText()) as List<Map<String, Any?>>
        for (m in list) {
            runCatching { entries.add(Entry(m["uri"] as String, (m["deleteAt"] as Number).toLong(), m["transferId"] as String)) }
        }
    }

    companion object {
        const val ACTION = "com.crossdrop.action.DELETE_EXPIRED"

        @Volatile
        private var instance: ExpiringDrops? = null

        fun get(context: Context): ExpiringDrops = instance ?: synchronized(this) {
            instance ?: ExpiringDrops(context.applicationContext).also { instance = it }
        }
    }
}

/**
 * Fires when an expiring drop is due (and after a restart, when alarms are lost).
 * Works without starting the engine, so it never turns networking on.
 */
class ExpiryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != ExpiringDrops.ACTION && action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val pending = goAsync()
        Thread {
            try {
                val gone = ExpiringDrops.get(context).purgeDue()
                if (gone.isNotEmpty()) Engine.peek()?.onDropsDeleted(gone)
            } finally {
                pending.finish()
            }
        }.start()
    }
}

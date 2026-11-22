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
 * MediaStore items when due: at app start, when the service starts, and from a
 * windowed, non-wakeup alarm (no exact-alarm permission; it may run late, never early,
 * and later still while the phone sleeps). Only deletions that were confirmed are
 * reported, so the app never says a file is gone when it is not.
 *
 * This is a courtesy, not a guarantee: the user could copy or share the file first,
 * and an item CrossDrop no longer owns (e.g. after a reinstall) cannot be deleted.
 */
class ExpiringDrops private constructor(private val context: Context) {
    private class Entry(val uri: String, val deleteAt: Long, val transferId: String)

    private val file = File(context.filesDir, "expiring.json")
    private val entries = ArrayList<Entry>()
    /** Transfers whose expiring files were all confirmed deleted (newest last, capped). */
    private val deletedFile = File(context.filesDir, "expiring-deleted.json")
    private val deleted = LinkedHashSet<String>()

    init {
        runCatching { load() }
        runCatching { loadDeleted() }
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

    /** True when every expiring file of [transferId] was confirmed deleted. */
    @Synchronized
    fun isDeleted(transferId: String): Boolean = transferId in deleted

    /**
     * Deletes every item that is due. Returns only the URIs CrossDrop confirmed deleting.
     * A failed delete (not CrossDrop's any more, or already gone; scoped storage can't
     * tell those apart) is not retried forever, and is not reported as deleted.
     */
    fun purgeDue(): List<String> {
        val due = synchronized(this) {
            val now = System.currentTimeMillis()
            entries.filter { it.deleteAt <= now }
        }
        if (due.isEmpty()) {
            schedule()
            return emptyList()
        }
        // Deleting talks to MediaStore; done outside the lock.
        val gone = due.filter { MediaStoreStorage.delete(context, it.uri) }
        val goneUris = gone.map { it.uri }.toSet()
        synchronized(this) {
            entries.removeAll { e -> due.any { it.uri == e.uri && it.deleteAt == e.deleteAt } }
            persist()
            // A transfer counts as deleted only when all of its files are confirmed gone.
            val changed = due.map { it.transferId }.distinct()
                .filter { id -> due.filter { it.transferId == id }.all { it.uri in goneUris } && entries.none { it.transferId == id } }
            if (changed.isNotEmpty()) {
                changed.forEach { deleted.remove(it); deleted.add(it) }
                while (deleted.size > MAX_DELETED) deleted.remove(deleted.first())
                persistDeleted()
            }
        }
        schedule()
        return goneUris.toList()
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
        // A window (no exact-alarm permission needed) keeps the lateness bounded while awake.
        val at = next.coerceAtLeast(System.currentTimeMillis() + 60_000)
        runCatching { am.setWindow(AlarmManager.RTC, at, ALARM_WINDOW_MS, pi) }
    }

    private fun persist() {
        val json = Json.write(entries.map { linkedMapOf("uri" to it.uri, "deleteAt" to it.deleteAt, "transferId" to it.transferId) })
        val tmp = File(file.parentFile, "expiring.json.tmp")
        tmp.writeText(json)
        tmp.renameTo(file)
    }

    private fun persistDeleted() {
        val tmp = File(deletedFile.parentFile, "expiring-deleted.json.tmp")
        tmp.writeText(Json.write(deleted.toList()))
        tmp.renameTo(deletedFile)
    }

    @Suppress("UNCHECKED_CAST")
    private fun loadDeleted() {
        if (!deletedFile.exists()) return
        (Json.parse(deletedFile.readText()) as List<Any?>).forEach { id -> (id as? String)?.let { deleted.add(it) } }
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
        private const val ALARM_WINDOW_MS = 15 * 60_000L
        /** Matches the history cap: older entries have scrolled out of history anyway. */
        private const val MAX_DELETED = HistoryRepository.MAX

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

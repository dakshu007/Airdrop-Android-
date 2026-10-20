package com.crossdrop.engine

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import com.crossdrop.core.CrossDropServer
import com.crossdrop.core.ErrorCode
import com.crossdrop.core.IncomingOffer
import com.crossdrop.core.IncomingTransfer
import com.crossdrop.core.LocalInfo
import com.crossdrop.core.OfferFile
import com.crossdrop.core.OutgoingFile
import com.crossdrop.core.OutgoingTransfer
import com.crossdrop.core.PairingPrompt
import com.crossdrop.core.PeerInfo
import com.crossdrop.core.Platform
import com.crossdrop.core.ProtocolException
import com.crossdrop.core.ReceiverEvents
import com.crossdrop.core.SavedFile
import com.crossdrop.core.SendStage
import com.crossdrop.core.SenderEvents
import com.crossdrop.core.TransferRejectedException
import com.crossdrop.core.deviceId
import com.crossdrop.core.fingerprint
import com.crossdrop.discovery.DiscoveredDevice
import com.crossdrop.discovery.NsdAdvertiser
import com.crossdrop.discovery.NsdDiscovery
import com.crossdrop.identity.KeystoreIdentity
import com.crossdrop.network.NetworkMonitor
import com.crossdrop.notifications.Notifier
import com.crossdrop.service.CrossDropService
import com.crossdrop.share.SharedFile
import com.crossdrop.storage.HistoryEntry
import com.crossdrop.storage.HistoryFile
import com.crossdrop.storage.HistoryRepository
import com.crossdrop.storage.MediaStoreStorage
import com.crossdrop.storage.Prefs
import com.crossdrop.storage.TrustRepository
import com.crossdrop.tiles.ReceiveTileService
import java.io.FileNotFoundException
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Owns all CrossDrop state on Android: receiving, discovery, transfers,
 * prompts and local history. The UI (React Native) only sees immutable
 * JSON snapshots and calls the command methods; file bytes stay native.
 *
 * Threading: state is guarded by [lock]; NSD callbacks arrive on the main
 * thread, transfer callbacks on worker threads.
 */
class Engine private constructor(private val app: Context) {
    val appContext: Context get() = app
    private val lock = Any()
    private val main = Handler(Looper.getMainLooper())
    private val workers = Executors.newCachedThreadPool { r -> Thread(r, "crossdrop-transfer").apply { isDaemon = true } }

    val prefs = Prefs(app)
    val identity = KeystoreIdentity.loadOrCreate()
    val trust = TrustRepository(app)
    val history = HistoryRepository(app)
    val notifier = Notifier(app)
    private val storage = MediaStoreStorage(app)
    private val network = NetworkMonitor(app) { onNetworkChanged() }
    private val advertiser = NsdAdvertiser(app) { err -> synchronized(lock) { receivingError = err }; changed() }
    private val discovery = NsdDiscovery(
        app,
        ownDeviceId = { identity.deviceId },
        onFound = { onDeviceFound(it) },
        onLost = { onDeviceLost(it) },
        onError = { err -> synchronized(lock) { discoveryError = err }; changed() },
    )

    // ---- state (guarded by lock) ----
    private var server: CrossDropServer? = null
    private var receivingEnabled = false
    private var receivingPort: Int? = null
    private var receivingError: String? = null
    private var autoOffAt: Long? = null
    private var discoveryWanted = false
    private var discoveryError: String? = null
    private val nearby = LinkedHashMap<String, DiscoveredDevice>()
    private val transfers = LinkedHashMap<String, TransferModel>()
    private val pairing = LinkedHashMap<String, PairingEntry>()
    private val offers = LinkedHashMap<String, IncomingOffer>()
    private var shared: List<SharedFile> = emptyList()
    private val outgoing = HashMap<String, OutgoingTransfer>()
    private val incoming = HashMap<String, IncomingTransfer>()
    private val sendRequests = HashMap<String, SendRequest>()

    class PairingEntry(val prompt: PairingPrompt, var waitingForPeer: Boolean)
    private class SendRequest(val deviceId: String, val files: List<SharedFile>)

    /** Receives a full snapshot JSON whenever state changes (coalesced, main thread). */
    var snapshotListener: ((String) -> Unit)? = null
    private var publishPending = false
    private var lastTileState = false

    init {
        trust.onChange = { changed() }
        network.start()
    }

    val localInfo: LocalInfo get() = LocalInfo(prefs.deviceName, Platform.ANDROID, APP_VERSION)

    // ---------------------------------------------------------------- receiving

    fun setReceiving(enabled: Boolean) {
        if (enabled) startReceiving() else stopReceiving()
    }

    private fun startReceiving() {
        synchronized(lock) {
            if (receivingEnabled) {
                scheduleAutoOff()
                return
            }
            receivingEnabled = true
            receivingError = null
        }
        // The foreground service must be up before work continues in the background.
        CrossDropService.update(app)
        workers.execute {
            val s = CrossDropServer(identity, { localInfo }, trust, storage, receiverEvents)
            val port = try {
                s.start(0)
            } catch (e: Exception) {
                synchronized(lock) {
                    receivingEnabled = false
                    receivingError = "listen_failed"
                }
                changed()
                CrossDropService.update(app)
                return@execute
            }
            val stillWanted = synchronized(lock) {
                if (receivingEnabled) {
                    server = s
                    receivingPort = port
                }
                receivingEnabled
            }
            if (!stillWanted) {
                s.stop()
                return@execute
            }
            network.setMulticast(true)
            advertiser.register(prefs.deviceName, port, identity.deviceId)
            main.post { scheduleAutoOff() }
            changed()
        }
        changed()
    }

    private fun stopReceiving() {
        val s = synchronized(lock) {
            receivingEnabled = false
            receivingPort = null
            autoOffAt = null
            receivingError = null
            server.also { server = null }
        }
        main.removeCallbacks(autoOff)
        advertiser.unregister()
        s?.stop() // In-flight inbound transfers keep their own connections.
        if (!discoveryWanted) network.setMulticast(false)
        changed()
        CrossDropService.update(app)
    }

    private val autoOff = Runnable {
        val busy = synchronized(lock) { incoming.isNotEmpty() || offers.isNotEmpty() || pairing.isNotEmpty() }
        if (busy) scheduleAutoOff(60_000) else stopReceiving()
    }

    private fun scheduleAutoOff(delayMs: Long = RECEIVE_AUTO_OFF_MS) {
        main.removeCallbacks(autoOff)
        synchronized(lock) {
            if (!receivingEnabled) return
            autoOffAt = System.currentTimeMillis() + delayMs
        }
        main.postDelayed(autoOff, delayMs)
        changed()
    }

    // ---------------------------------------------------------------- discovery

    fun startDiscovery() {
        synchronized(lock) { discoveryWanted = true }
        network.setMulticast(true)
        discovery.start()
        changed()
    }

    fun stopDiscovery() {
        synchronized(lock) {
            discoveryWanted = false
            nearby.clear()
        }
        discovery.stop()
        if (!synchronized(lock) { receivingEnabled }) network.setMulticast(false)
        changed()
    }

    private fun onDeviceFound(d: DiscoveredDevice) {
        synchronized(lock) {
            nearby.values.removeAll { it.serviceName == d.serviceName && it.deviceId != d.deviceId }
            nearby[d.deviceId] = d
        }
        changed()
    }

    private fun onDeviceLost(serviceName: String) {
        synchronized(lock) { nearby.values.removeAll { it.serviceName == serviceName } }
        changed()
    }

    private fun onNetworkChanged() {
        main.post {
            val (recv, port, disc) = synchronized(lock) { Triple(receivingEnabled, receivingPort, discoveryWanted) }
            // Re-announce and re-browse on the new network.
            if (recv && port != null && network.localNetwork) advertiser.register(prefs.deviceName, port, identity.deviceId)
            if (disc) {
                discovery.stop()
                synchronized(lock) { nearby.clear() }
                if (network.localNetwork) discovery.start()
            }
            changed()
        }
    }

    // ---------------------------------------------------------------- sending

    /** Starts sending [files] to a discovered device. Returns the transfer id. */
    fun send(deviceId: String, files: List<SharedFile>): String {
        require(files.isNotEmpty()) { "no files" }
        val device = synchronized(lock) { nearby[deviceId] } ?: throw IllegalStateException("unreachable")
        val id = UUID.randomUUID().toString()
        val model = TransferModel(
            id = id,
            direction = "outgoing",
            peerId = deviceId,
            peerName = trust.get(deviceId)?.name ?: device.name,
            peerPlatform = device.platform.wire,
            files = files.map { FileModel(it.name, it.size ?: 0, it.mime) }.toMutableList(),
        )
        model.status = "preparing"
        synchronized(lock) {
            transfers[id] = model
            sendRequests[id] = SendRequest(deviceId, files)
        }
        // Hand the URIs to the service so the read grant outlives the activity.
        CrossDropService.update(app, files.map { Uri.parse(it.uri) })

        val outgoingFiles = files.map { f ->
            OutgoingFile(f.name, f.size, f.mime) {
                app.contentResolver.openInputStream(Uri.parse(f.uri)) ?: throw FileNotFoundException("unreadable")
            }
        }
        val transfer = OutgoingTransfer(identity, localInfo, trust, device.host, device.port, deviceId, outgoingFiles, SendEvents(model), id)
        synchronized(lock) { outgoing[id] = transfer }
        changed()

        workers.execute {
            try {
                val peer = transfer.run()
                finish(model, "completed", null, null, peer)
            } catch (e: TransferRejectedException) {
                finish(model, "rejected", null, e.reason, null)
            } catch (e: ProtocolException) {
                if (e.code == ErrorCode.CANCELLED) finish(model, "cancelled", e, null, null)
                else finish(model, "failed", e, null, null)
            } catch (e: Exception) {
                finish(model, "failed", ProtocolException(ErrorCode.INTERNAL, e.javaClass.simpleName), null, null)
            }
        }
        return id
    }

    fun retry(transferId: String): String {
        val req = synchronized(lock) { sendRequests[transferId] } ?: throw IllegalStateException("not retryable")
        val newId = send(req.deviceId, req.files)
        dismiss(transferId)
        return newId
    }

    private inner class SendEvents(private val model: TransferModel) : SenderEvents {
        override fun onStage(stage: SendStage) {
            update(model) {
                status = when (stage) {
                    SendStage.PREPARING -> "preparing"
                    SendStage.CONNECTING -> "connecting"
                    SendStage.PAIRING -> "pairing"
                    SendStage.WAITING_FOR_ACCEPTANCE -> "waitingForAcceptance"
                    SendStage.TRANSFERRING -> "transferring"
                }
                if (stage == SendStage.TRANSFERRING) rate.reset()
            }
        }

        override fun onPrepared(files: List<OfferFile>) {
            update(model) {
                files.forEachIndexed { i, f -> this.files[i] = this.files[i].copy(size = f.size) }
            }
        }

        override fun onConnected(peer: PeerInfo) {
            update(model) { peerName = trust.get(peer.deviceId)?.name ?: peer.name }
        }

        override fun onBytesSent(total: Long) {
            update(model, publish = false) {
                bytesTransferred = total
                var left = total
                for (i in files.indices) {
                    val f = files[i]
                    val b = minOf(left, f.size)
                    if (f.bytes != b) files[i] = f.copy(bytes = b)
                    left -= b
                }
                rate.sample(total)
            }
            changedThrottled()
        }

        override fun onPairingPrompt(prompt: PairingPrompt) = addPairing(prompt)
        override fun onPairingWaitingForPeer(prompt: PairingPrompt) = pairingWaiting(prompt)
        override fun onPairingClosed(prompt: PairingPrompt, paired: Boolean) = removePairing(prompt)
    }

    fun cancel(transferId: String) {
        val (out, inc) = synchronized(lock) { outgoing[transferId] to incoming[transferId] }
        if (out != null) workers.execute { out.cancel() }
        if (inc != null) workers.execute { inc.cancel() }
    }

    fun dismiss(transferId: String) {
        synchronized(lock) {
            val t = transfers[transferId] ?: return
            if (!t.isFinished) return
            transfers.remove(transferId)
            sendRequests.remove(transferId)
        }
        changed()
    }

    // ---------------------------------------------------------------- receiving events

    private val receiverEvents = object : ReceiverEvents {
        override fun isReceiving(): Boolean = synchronized(lock) { receivingEnabled }

        override fun onPairingPrompt(prompt: PairingPrompt) {
            addPairing(prompt)
            notifier.request(prompt.sessionId, "Pair with ${prompt.peer.name}?", "Check that the code matches on both devices.")
        }

        override fun onPairingWaitingForPeer(prompt: PairingPrompt) = pairingWaiting(prompt)

        override fun onPairingClosed(prompt: PairingPrompt, paired: Boolean) {
            notifier.cancel(prompt.sessionId)
            removePairing(prompt)
        }

        override fun onOffer(offer: IncomingOffer) {
            synchronized(lock) { offers[offer.transferId] = offer }
            val count = offer.files.size
            notifier.request(
                offer.transferId,
                "${offer.peer.name} wants to send you ${if (count == 1) "a file" else "$count files"}",
                "Open CrossDrop to accept or decline.",
            )
            changed()
        }

        override fun onOfferClosed(offer: IncomingOffer) {
            notifier.cancel(offer.transferId)
            synchronized(lock) { offers.remove(offer.transferId) }
            changed()
        }

        override fun onRejected(offer: IncomingOffer, reason: String) {
            history.add(
                HistoryEntry(
                    offer.transferId, "incoming", offer.peer.name, offer.peer.platform.wire, "rejected",
                    offer.files.map { HistoryFile(it.name, it.size, null) }, offer.totalBytes, System.currentTimeMillis(), reason,
                ),
            )
            changed()
        }

        override fun onTransferStarted(transfer: IncomingTransfer) {
            val model = TransferModel(
                id = transfer.transferId,
                direction = "incoming",
                peerId = transfer.peer.deviceId,
                peerName = transfer.peer.name,
                peerPlatform = transfer.peer.platform.wire,
                files = transfer.files.map { FileModel(it.name, it.size, it.mime) }.toMutableList(),
            )
            model.status = "transferring"
            synchronized(lock) {
                transfers[model.id] = model
                incoming[model.id] = transfer
            }
            CrossDropService.update(app)
            changed()
        }

        override fun onProgress(transfer: IncomingTransfer, fileIndex: Int, fileBytes: Long, totalBytes: Long) {
            val model = synchronized(lock) { transfers[transfer.transferId] } ?: return
            update(model, publish = false) {
                files[fileIndex] = files[fileIndex].copy(bytes = fileBytes)
                bytesTransferred = totalBytes
                rate.sample(totalBytes)
            }
            changedThrottled()
        }

        override fun onFileSaved(transfer: IncomingTransfer, fileIndex: Int, saved: SavedFile) {
            val model = synchronized(lock) { transfers[transfer.transferId] } ?: return
            update(model) { files[fileIndex] = files[fileIndex].copy(name = saved.displayName, uri = saved.location) }
        }

        override fun onCompleted(transfer: IncomingTransfer) {
            val model = synchronized(lock) { transfers[transfer.transferId] } ?: return
            finish(model, "completed", null, null, transfer.peer)
        }

        override fun onFailed(transfer: IncomingTransfer?, peer: PeerInfo?, error: ProtocolException) {
            if (transfer == null) return // Handshake noise or a declined pairing; nothing to show.
            val model = synchronized(lock) { transfers[transfer.transferId] } ?: return
            finish(model, if (error.code == ErrorCode.CANCELLED) "cancelled" else "failed", error, null, peer)
        }
    }

    // ---------------------------------------------------------------- prompts

    private fun addPairing(prompt: PairingPrompt) {
        synchronized(lock) { pairing[prompt.sessionId] = PairingEntry(prompt, false) }
        changed()
    }

    private fun pairingWaiting(prompt: PairingPrompt) {
        synchronized(lock) { pairing[prompt.sessionId]?.waitingForPeer = true }
        changed()
    }

    private fun removePairing(prompt: PairingPrompt) {
        synchronized(lock) { pairing.remove(prompt.sessionId) }
        changed()
    }

    fun respondToPairing(sessionId: String, accept: Boolean) {
        synchronized(lock) { pairing[sessionId] }?.prompt?.respond(accept)
    }

    fun respondToOffer(transferId: String, accept: Boolean) {
        synchronized(lock) { offers[transferId] }?.respond(accept)
    }

    // ---------------------------------------------------------------- shared files, devices, history

    fun setShared(files: List<SharedFile>) {
        synchronized(lock) { shared = files }
        changed()
    }

    fun clearShared() = setShared(emptyList())

    fun forget(deviceId: String) = trust.forget(deviceId)

    fun setAutoAccept(deviceId: String, enabled: Boolean) = trust.setAutoAccept(deviceId, enabled)

    fun setDeviceName(name: String) {
        prefs.deviceName = name
        val port = synchronized(lock) { receivingPort }
        if (port != null) advertiser.register(prefs.deviceName, port, identity.deviceId)
        changed()
    }

    fun clearHistory() {
        history.clear()
        changed()
    }

    // ---------------------------------------------------------------- lifecycle helpers

    private fun finish(model: TransferModel, status: String, error: ProtocolException?, rejectReason: String?, peer: PeerInfo?) {
        val entry: HistoryEntry
        synchronized(lock) {
            model.status = status
            model.error = error?.let { it.code.wire }
            model.rejectReason = rejectReason
            model.updatedAt = System.currentTimeMillis()
            model.canRetry = model.direction == "outgoing" && (status == "failed" || status == "cancelled") && sendRequests.containsKey(model.id)
            if (status == "completed") model.bytesTransferred = model.totalBytes
            outgoing.remove(model.id)
            incoming.remove(model.id)
            if (!model.canRetry) sendRequests.remove(model.id)
            entry = HistoryEntry(
                model.id, model.direction, model.peerName, model.peerPlatform, status,
                model.files.map { HistoryFile(it.name, it.size, it.uri) }, model.totalBytes, model.updatedAt, model.error ?: rejectReason,
            )
        }
        history.add(entry)
        if (model.direction == "incoming") {
            val n = model.files.size
            when (status) {
                "completed" -> notifier.result(model.id, "Received ${if (n == 1) "1 file" else "$n files"} from ${model.peerName}", "Saved to ${MediaStoreStorage.LABEL}")
                "failed" -> notifier.result(model.id, "Transfer from ${model.peerName} failed", "Nothing incomplete was kept.")
            }
            if (synchronized(lock) { receivingEnabled }) main.post { scheduleAutoOff() }
        } else if (status == "completed" || status == "failed") {
            notifier.result(model.id, if (status == "completed") "Sent to ${model.peerName}" else "Couldn’t send to ${model.peerName}", if (status == "completed") "All files verified on the other device." else "Open CrossDrop for details.")
        }
        changed()
        CrossDropService.update(app)
    }

    private inline fun update(model: TransferModel, publish: Boolean = true, block: TransferModel.() -> Unit) {
        synchronized(lock) {
            model.block()
            model.updatedAt = System.currentTimeMillis()
        }
        if (publish) changed()
    }

    /** True while the foreground service is needed. */
    fun needsService(): Boolean = synchronized(lock) {
        receivingEnabled || transfers.values.any { !it.isFinished }
    }

    /** Text for the foreground notification. */
    fun serviceStatus(): Triple<String, String, Int?> = synchronized(lock) {
        val active = transfers.values.filter { !it.isFinished }
        when {
            active.isNotEmpty() -> {
                val t = active.first()
                val total = active.sumOf { it.totalBytes }.coerceAtLeast(1)
                val done = active.sumOf { it.bytesTransferred }
                val verb = if (t.direction == "outgoing") "Sending to" else "Receiving from"
                val title = if (active.size == 1) "$verb ${t.peerName}" else "${active.size} transfers in progress"
                Triple(title, "Tap to see progress", if (active.any { it.status == "transferring" }) (done * 100 / total).toInt() else null)
            }
            else -> Triple("Receiving is on", "Visible to nearby devices as ${prefs.deviceName}", null)
        }
    }

    // ---------------------------------------------------------------- snapshots

    private var lastThrottled = 0L

    private fun changedThrottled() {
        val now = System.currentTimeMillis()
        if (now - lastThrottled >= 250) {
            lastThrottled = now
            changed()
        }
    }

    fun changed() {
        main.post {
            if (publishPending) return@post
            publishPending = true
            main.postDelayed({
                publishPending = false
                val json = snapshotJson()
                snapshotListener?.invoke(json)
                CrossDropService.refreshNotification(app)
                if (lastTileState != isReceiving) {
                    lastTileState = isReceiving
                    ReceiveTileService.requestRefresh(app)
                }
            }, 50)
        }
    }

    fun snapshotJson(): String = synchronized(lock) {
        Snapshots.build(this, SnapshotState(
            receivingEnabled, receivingPort, receivingError, autoOffAt,
            discoveryWanted && discovery.isActive, discoveryError, network.localNetwork,
            nearby.values.toList(), transfers.values.toList(), pairing.values.toList(), offers.values.toList(), shared,
        ))
    }

    fun openFileIntent(uri: String): Intent {
        val u = Uri.parse(uri)
        return Intent(Intent.ACTION_VIEW)
            .setDataAndType(u, app.contentResolver.getType(u) ?: "*/*")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    val isReceiving: Boolean get() = synchronized(lock) { receivingEnabled }

    val deviceId: String get() = identity.deviceId
    val fingerprint: String get() = identity.fingerprint

    companion object {
        const val APP_VERSION = "0.1.0"
        const val RECEIVE_AUTO_OFF_MS = 10 * 60 * 1000L

        @Volatile
        private var instance: Engine? = null

        fun get(context: Context): Engine = instance ?: synchronized(this) {
            instance ?: Engine(context.applicationContext).also { instance = it }
        }

        fun peek(): Engine? = instance
    }
}

/** Immutable view of engine state used to build a snapshot. */
class SnapshotState(
    val receivingEnabled: Boolean,
    val receivingPort: Int?,
    val receivingError: String?,
    val autoOffAt: Long?,
    val discoveryActive: Boolean,
    val discoveryError: String?,
    val localNetwork: Boolean,
    val nearby: List<DiscoveredDevice>,
    val transfers: List<TransferModel>,
    val pairing: List<Engine.PairingEntry>,
    val offers: List<IncomingOffer>,
    val shared: List<SharedFile>,
)

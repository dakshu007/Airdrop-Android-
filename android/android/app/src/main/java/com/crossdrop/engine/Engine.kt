package com.crossdrop.engine

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.crossdrop.core.CrossDropServer
import com.crossdrop.core.ErrorCode
import com.crossdrop.core.IncomingOffer
import com.crossdrop.core.IncomingTransfer
import com.crossdrop.core.LocalInfo
import com.crossdrop.core.OfferFile
import com.crossdrop.core.OfferKind
import com.crossdrop.core.OutgoingFile
import com.crossdrop.core.OutgoingTransfer
import com.crossdrop.core.PairingPrompt
import com.crossdrop.core.PeerInfo
import com.crossdrop.core.Platform
import com.crossdrop.core.ProtocolException
import com.crossdrop.core.QrPairing
import com.crossdrop.core.QrPairingClient
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
import com.crossdrop.feedback.Feedback
import com.crossdrop.identity.KeystoreIdentity
import com.crossdrop.network.NetworkMonitor
import com.crossdrop.notifications.NotificationActionReceiver
import com.crossdrop.notifications.Notifier
import com.crossdrop.pairing.PairingCode
import com.crossdrop.screenshots.ScreenshotWatcher
import com.crossdrop.service.CrossDropService
import com.crossdrop.share.DirectShare
import com.crossdrop.share.SharedFile
import com.crossdrop.share.SharedFiles
import com.crossdrop.share.SharedText
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
    val feedback = Feedback(app, prefs)
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
    private var sharedText: SharedText? = null
    /** Open to everyone (timed); otherwise, while receiving, only paired devices get in (§9.5). */
    private var everyoneOpen = false
    /** Direct Share: send these to this device as soon as it is reachable. */
    private var pendingDirect: SendRequest? = null
    private val outgoing = HashMap<String, OutgoingTransfer>()
    private val incoming = HashMap<String, IncomingTransfer>()
    private val sendRequests = HashMap<String, SendRequest>()

    class PairingEntry(val prompt: PairingPrompt, var waitingForPeer: Boolean)
    private class SendRequest(val deviceId: String, val files: List<SharedFile>, val text: SharedText? = null)
    private class Endpoint(val host: String, val port: Int, val name: String, val platform: String)

    private val screenshots = ScreenshotWatcher(app) { uri, name -> onScreenshot(uri, name) }

    /** Receives a full snapshot JSON whenever state changes (coalesced, main thread). */
    var snapshotListener: ((String) -> Unit)? = null
    private var publishPending = false
    private var lastTileState = false

    init {
        trust.onChange = {
            publishDirectShare()
            changed()
        }
        network.start()
        main.post {
            restoreReceiving()
            updateScreenshotWatcher()
        }
    }

    val localInfo: LocalInfo get() = LocalInfo(prefs.deviceName, Platform.ANDROID, APP_VERSION)

    // ---------------------------------------------------------------- receiving

    /** Tile and legacy callers: on opens to everyone for a while, off turns receiving off entirely. */
    fun setReceiving(enabled: Boolean) = setReceiveMode(if (enabled) "everyone" else "off")

    /**
     * "off"; "mine" — always reachable by paired devices, invisible to others (§9.5);
     * "everyone" — anyone nearby for [RECEIVE_AUTO_OFF_MS], then back to the base mode.
     */
    fun setReceiveMode(mode: String) {
        when (mode) {
            "off" -> {
                prefs.receiveBase = "off"
                stopReceiving()
            }
            "mine" -> {
                prefs.receiveBase = "mine"
                synchronized(lock) { everyoneOpen = false; autoOffAt = null }
                main.removeCallbacks(autoOff)
                if (isReceiving) advertise() else startReceiving()
                changed()
            }
            "everyone" -> {
                synchronized(lock) { everyoneOpen = true }
                if (isReceiving) {
                    advertise()
                    scheduleAutoOff()
                } else {
                    startReceiving()
                }
            }
        }
        updateScreenshotWatcher()
    }

    /** After a restart or app launch: brings back "My devices only" if the user chose it. */
    fun restoreReceiving() {
        if (prefs.receiveBase == "mine" && !isReceiving) setReceiveMode("mine")
    }

    private fun privateMode(): Boolean = synchronized(lock) { receivingEnabled && !everyoneOpen }

    /** (Re)announces this device: by name when open to everyone, privately otherwise. */
    private fun advertise() {
        val port = synchronized(lock) { receivingPort } ?: return
        advertiser.register(prefs.deviceName, port, identity.deviceId, private = privateMode())
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
            val s = CrossDropServer(identity, { localInfo }, trust, storage, receiverEvents, { privateMode() })
            // A stable port lets paired devices reach this phone at its last address when
            // discovery is blocked (§9.5); any free port works too, discovery announces it.
            val port = try {
                try {
                    s.start(PREFERRED_PORT)
                } catch (e: java.io.IOException) {
                    s.start(0)
                }
            } catch (e: Exception) {
                synchronized(lock) {
                    receivingEnabled = false
                    receivingError = "listen_failed"
                }
                changed()
                CrossDropService.update(app)
                return@execute
            }
            // The port is random and also announced over DNS-SD; logging it lets tools find the listener.
            Log.i(TAG, "Receiving on port $port")
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
            advertise()
            main.post { if (synchronized(lock) { everyoneOpen }) scheduleAutoOff() }
            changed()
        }
        changed()
    }

    private fun stopReceiving() {
        val s = synchronized(lock) {
            receivingEnabled = false
            everyoneOpen = false
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
        when {
            busy -> scheduleAutoOff(60_000)
            // The "everyone" window closes; paired devices can still reach this phone.
            prefs.receiveBase == "mine" -> setReceiveMode("mine")
            else -> stopReceiving()
        }
    }

    private fun scheduleAutoOff(delayMs: Long = RECEIVE_AUTO_OFF_MS) {
        main.removeCallbacks(autoOff)
        synchronized(lock) {
            if (!receivingEnabled || !everyoneOpen) return
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
        // "My devices only" receivers are listed only for devices that already paired with them.
        if (d.private && trust.get(d.deviceId) == null) return
        val isNew: Boolean
        synchronized(lock) {
            nearby.values.removeAll { it.serviceName == d.serviceName && it.deviceId != d.deviceId }
            isNew = nearby.put(d.deviceId, d) == null
        }
        if (isNew) synchronized(lock) { newestDeviceAt = System.currentTimeMillis() }
        changed()
        val direct = synchronized(lock) { pendingDirect?.takeIf { it.deviceId == d.deviceId }?.also { pendingDirect = null } }
        if (direct != null) workers.execute { runCatching { send(direct.deviceId, direct.files) }.onSuccess { clearShared() } }
    }

    /** When a new device last appeared (the UI greets it with a small wave). */
    private var newestDeviceAt = 0L

    private fun onDeviceLost(serviceName: String) {
        synchronized(lock) { nearby.values.removeAll { it.serviceName == serviceName } }
        changed()
    }

    private fun onNetworkChanged() {
        main.post {
            val (recv, port, disc) = synchronized(lock) { Triple(receivingEnabled, receivingPort, discoveryWanted) }
            // Re-announce and re-browse on the new network.
            if (recv && port != null && network.localNetwork) advertise()
            if (disc) {
                discovery.stop()
                synchronized(lock) { nearby.clear() }
                if (network.localNetwork) discovery.start()
            }
            changed()
        }
    }

    // ---------------------------------------------------------------- sending

    /** Where a device can be reached: its discovered address, else the last one that worked (§9.5). */
    private fun endpoint(deviceId: String): Endpoint? {
        synchronized(lock) { nearby[deviceId] }?.let { return Endpoint(it.host, it.port, it.name, it.platform.wire) }
        val peer = trust.get(deviceId) ?: return null
        val (host, port) = trust.lastAddress(deviceId) ?: return null
        return Endpoint(host, port, peer.name, peer.platform.wire)
    }

    /** Starts sending [files] to a nearby or remembered device. Returns the transfer id. */
    fun send(deviceId: String, files: List<SharedFile>): String {
        require(files.isNotEmpty()) { "no files" }
        val outgoingFiles = files.map { f ->
            OutgoingFile(f.name, f.size, f.mime, f.path) {
                app.contentResolver.openInputStream(Uri.parse(f.uri)) ?: throw FileNotFoundException("unreadable")
            }
        }
        // Hand the URIs to the service so the read grant outlives the activity.
        return start(deviceId, SendRequest(deviceId, files), OfferKind.FILES, outgoingFiles,
            files.map { FileModel((it.path + it.name).joinToString("/"), it.size ?: 0, it.mime) }, files.map { Uri.parse(it.uri) })
    }

    /** Sends a link or text (§9.2); it opens or lands on the clipboard there, and is never saved as a file. */
    fun sendText(deviceId: String, text: SharedText): String {
        val kind = if (text.kind == "link") OfferKind.LINK else OfferKind.TEXT
        val name = if (kind == OfferKind.LINK) "Link" else "Text"
        val file = OutgoingFile.text(name, text.text)
        val id = start(deviceId, SendRequest(deviceId, emptyList(), text), kind, listOf(file),
            listOf(FileModel(name, file.size ?: 0, file.mime)), emptyList())
        synchronized(lock) {
            transfers[id]?.let { m ->
                m.kind = kind.wire
                m.text = if (kind == OfferKind.LINK) text.text else null
            }
        }
        return id
    }

    /** Sends the link / text currently handed over by the share sheet or clipboard. */
    fun sendSharedText(deviceId: String): String {
        val text = synchronized(lock) { sharedText } ?: throw IllegalStateException("nothing to send")
        return sendText(deviceId, text)
    }

    private fun start(
        deviceId: String,
        request: SendRequest,
        kind: OfferKind,
        outgoingFiles: List<OutgoingFile>,
        models: List<FileModel>,
        grants: List<Uri>,
    ): String {
        val target = endpoint(deviceId) ?: throw IllegalStateException("unreachable")
        val id = UUID.randomUUID().toString()
        val model = TransferModel(
            id = id,
            direction = "outgoing",
            peerId = deviceId,
            peerName = trust.get(deviceId)?.name ?: target.name,
            peerPlatform = target.platform,
            files = models.toMutableList(),
        )
        model.status = "preparing"
        model.kind = kind.wire
        synchronized(lock) {
            transfers[id] = model
            sendRequests[id] = request
        }
        CrossDropService.update(app, grants)

        val transfer = OutgoingTransfer(identity, localInfo, trust, target.host, target.port, deviceId, outgoingFiles,
            SendEvents(model, target), id, kind)
        synchronized(lock) { outgoing[id] = transfer }
        changed()

        workers.execute {
            try {
                val peer = transfer.run()
                prefs.lastDeviceId = peer.deviceId
                trust.rememberAddress(peer.deviceId, target.host, target.port)
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
        val newId = if (req.text != null) sendText(req.deviceId, req.text) else send(req.deviceId, req.files)
        dismiss(transferId)
        return newId
    }

    /**
     * "Send again" from history: the same files (if this phone can still read them)
     * or link, to [deviceId] (default: the device it went to before).
     */
    fun resend(historyId: String, deviceId: String?): String {
        val entry = history.get(historyId) ?: throw IllegalStateException("gone")
        val target = deviceId ?: entry.peerId ?: throw IllegalStateException("unreachable")
        if (entry.kind == "link") return sendText(target, SharedText("link", entry.link ?: throw IllegalStateException("gone")))
        val files = entry.files.map { f ->
            val uri = f.uri ?: throw FileNotFoundException("unreadable")
            // Only sources CrossDrop still has access to (picked files keep a lasting grant).
            app.contentResolver.openInputStream(Uri.parse(uri))?.close() ?: throw FileNotFoundException("unreadable")
            SharedFiles.describe(app, Uri.parse(uri))
        }
        if (files.isEmpty()) throw FileNotFoundException("unreadable")
        return send(target, files)
    }

    /**
     * Direct Share: the user picked a paired device in the share sheet. Sends at once
     * when it is reachable; otherwise looks for it for a short while, and leaves the
     * files on screen to send by hand if it doesn't show up.
     */
    fun sendWhenReachable(deviceId: String, files: List<SharedFile>, text: SharedText?) {
        if (endpoint(deviceId) != null) {
            runCatching { if (text != null) sendText(deviceId, text) else send(deviceId, files) }
                .onSuccess { clearShared() }
            return
        }
        if (text != null) return // Links and text wait on screen; no background search for them.
        synchronized(lock) { pendingDirect = SendRequest(deviceId, files) }
        startDiscovery()
        main.postDelayed({ synchronized(lock) { if (pendingDirect?.deviceId == deviceId) pendingDirect = null } }, 20_000)
    }

    private inner class SendEvents(private val model: TransferModel, private val target: Endpoint) : SenderEvents {
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
            // Already paired and the handshake proved it: this address works.
            trust.rememberAddress(peer.deviceId, target.host, target.port)
        }

        override fun onPairingClosed(prompt: PairingPrompt, paired: Boolean) {
            removePairing(prompt)
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

    // ---------------------------------------------------------------- foreground

    /** True while CrossDrop is on screen; requests then show in the app, not as heads-up notifications. */
    @Volatile
    private var appVisible = false

    fun setAppVisible(visible: Boolean) {
        appVisible = visible
        val (prompts, pending) = synchronized(lock) { pairing.values.map { it.prompt } to offers.values.toList() }
        if (visible) {
            prompts.forEach { notifier.cancel(it.sessionId) }
            pending.forEach { notifier.cancel(it.transferId) }
        } else {
            // Leaving the app with a decision pending: make sure it can still be found.
            prompts.forEach(::notifyPairing)
            pending.forEach(::notifyOffer)
        }
    }

    private fun notifyPairing(prompt: PairingPrompt) =
        notifier.request(prompt.sessionId, "Pair with ${prompt.peer.name}?", "Check that the code matches on both devices.")

    private fun notifyOffer(offer: IncomingOffer) {
        val count = offer.files.size
        val what = when (offer.kind) {
            OfferKind.LINK -> "a link"
            OfferKind.TEXT -> "some text"
            OfferKind.FILES -> if (count == 1) "a file" else "$count files"
        }
        notifier.request(
            offer.transferId,
            "${offer.peer.name} wants to send you $what",
            "Accept here, or open CrossDrop to see the details.",
            listOf(
                notifier.action("Accept", NotificationActionReceiver.ACCEPT, offer.transferId),
                notifier.action("Decline", NotificationActionReceiver.DECLINE, offer.transferId),
            ),
        )
    }

    // ---------------------------------------------------------------- receiving events

    private val receiverEvents = object : ReceiverEvents {
        override fun isReceiving(): Boolean = synchronized(lock) { receivingEnabled }

        override fun onPairingPrompt(prompt: PairingPrompt) {
            addPairing(prompt)
            if (!appVisible) notifyPairing(prompt)
        }

        override fun onPairingWaitingForPeer(prompt: PairingPrompt) = pairingWaiting(prompt)

        override fun onPairingClosed(prompt: PairingPrompt, paired: Boolean) {
            notifier.cancel(prompt.sessionId)
            removePairing(prompt)
        }

        override fun onOffer(offer: IncomingOffer) {
            synchronized(lock) { offers[offer.transferId] = offer }
            if (!appVisible) notifyOffer(offer)
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

        override fun onTextReceived(transfer: IncomingTransfer, kind: OfferKind, text: String) {
            val model = synchronized(lock) { transfers[transfer.transferId] } ?: return
            update(model) {
                this.kind = kind.wire
                this.text = text
            }
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
            model.kind = transfer.kind.wire
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

    /** [mine]: "This is my device" — its transfers are accepted without asking from now on. */
    fun respondToPairing(sessionId: String, accept: Boolean, mine: Boolean = false) {
        synchronized(lock) { pairing[sessionId] }?.prompt?.respond(accept, mine)
    }

    /**
     * Pairs with the device in a scanned QR code (§9.4) without comparing numbers:
     * the code names the receiver's key, and the handshake proves it. Blocking;
     * returns the paired device's name.
     */
    fun pairWithCode(raw: String, mine: Boolean): String {
        val code = PairingCode.parse(raw) ?: throw IllegalArgumentException("bad_code")
        val qr = QrPairing(code.token, code.fingerprint, mine)
        val quiet = object : com.crossdrop.core.PairingEvents {
            override fun onPairingPrompt(prompt: PairingPrompt) {}
            override fun onPairingClosed(prompt: PairingPrompt, paired: Boolean) {}
        }
        var last: Exception = ProtocolException(ErrorCode.UNREACHABLE, "no address")
        for (host in code.hosts) {
            try {
                val peer = QrPairingClient.pairOnly(identity, localInfo, trust, listOf(host), code.port, qr, quiet)
                trust.rememberAddress(peer.deviceId, host, code.port)
                prefs.lastDeviceId = peer.deviceId
                changed()
                return trust.get(peer.deviceId)?.name ?: peer.name
            } catch (e: ProtocolException) {
                last = e
                if (e.code != ErrorCode.UNREACHABLE) throw e
            }
        }
        throw last
    }

    fun respondToOffer(transferId: String, accept: Boolean) {
        synchronized(lock) { offers[transferId] }?.respond(accept)
    }

    // ---------------------------------------------------------------- shared files, devices, history

    fun setShared(files: List<SharedFile>) {
        synchronized(lock) {
            shared = files
            if (files.isNotEmpty()) sharedText = null
        }
        changed()
    }

    /** A link or text to hand off, from the share sheet or the clipboard. */
    fun setSharedText(text: SharedText?) {
        synchronized(lock) {
            sharedText = text
            if (text != null) shared = emptyList()
        }
        changed()
    }

    fun clearShared() {
        synchronized(lock) {
            shared = emptyList()
            sharedText = null
        }
        changed()
    }

    /**
     * Reads the clipboard once (only possible while CrossDrop is on screen) and offers
     * it for sending. Returns false when there is nothing usable on it.
     */
    fun takeClipboard(): Boolean {
        val cm = app.getSystemService(ClipboardManager::class.java) ?: return false
        val item = runCatching { cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0) }.getOrNull() ?: return false
        val text = item.coerceToText(app)?.toString()?.let { SharedText.of(it) } ?: return false
        setSharedText(text)
        return true
    }

    /** Notification "Copy": puts received text on this phone's clipboard. */
    fun copyReceivedText(transferId: String) {
        val text = synchronized(lock) { transfers[transferId]?.text } ?: return
        main.post {
            val cm = app.getSystemService(ClipboardManager::class.java) ?: return@post
            cm.setPrimaryClip(ClipData.newPlainText("CrossDrop", text))
        }
    }

    // ---------------------------------------------------------------- screenshots

    fun setScreenshotOffer(enabled: Boolean) {
        prefs.screenshotOffer = enabled
        updateScreenshotWatcher()
        changed()
    }

    fun updateScreenshotWatcher() {
        // Only while CrossDrop is running anyway (receiving); it never keeps the app alive by itself.
        if (prefs.screenshotOffer && isReceiving && screenshots.hasPermission()) screenshots.start() else screenshots.stop()
    }

    private fun onScreenshot(uri: Uri, name: String) {
        val deviceId = prefs.lastDeviceId ?: return
        val peer = trust.get(deviceId) ?: return
        notifier.suggestion(
            "screenshot", "Send screenshot to ${peer.name}?", "Tap Send to share it now.",
            listOf(notifier.action("Send", NotificationActionReceiver.SEND_SCREENSHOT, deviceId, uri.toString())),
        )
    }

    fun sendScreenshot(deviceId: String, uri: String) {
        workers.execute {
            runCatching { send(deviceId, listOf(SharedFiles.describe(app, Uri.parse(uri)))) }
                .onFailure { notifier.result("screenshot-failed", "Couldn’t send the screenshot", "Open CrossDrop to try again.") }
        }
    }

    private fun publishDirectShare() {
        workers.execute { DirectShare.publish(app, trust.all()) }
    }

    fun forget(deviceId: String) = trust.forget(deviceId)

    fun setAutoAccept(deviceId: String, enabled: Boolean) = trust.setAutoAccept(deviceId, enabled)

    fun setDeviceName(name: String) {
        prefs.deviceName = name
        val port = synchronized(lock) { receivingPort }
        if (port != null) advertiser.register(prefs.deviceName, port, identity.deviceId)
        changed()
    }

    /** Known keys: 'sound', 'haptics', 'welcomed'. Unknown keys are ignored. */
    fun setPreference(key: String, value: Boolean) {
        when (key) {
            "sound" -> prefs.sound = value
            "haptics" -> prefs.haptics = value
            "welcomed" -> prefs.welcomed = value
            else -> return
        }
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
                peerId = model.peerId,
                kind = model.kind,
                // Links are kept so they can be sent again; text content never goes to history.
                link = if (model.kind == "link") model.text?.take(2048) else null,
            )

        }
        history.add(entry)
        if (model.direction == "incoming") {
            val n = model.files.size
            val text = model.text
            when {
                status == "completed" && model.kind == "link" && text != null && isWebLink(text) -> notifier.result(
                    model.id, "Link from ${model.peerName}", text.take(200),
                    listOf(
                        notifier.activityAction("Open", model.id, linkIntent(text)),
                        notifier.action("Copy", NotificationActionReceiver.COPY, model.id),
                    ),
                    tap = notifier.activityIntent(model.id, linkIntent(text)),
                )
                status == "completed" && model.kind != "files" -> notifier.result(
                    model.id, "Text from ${model.peerName}", "Tap Copy to put it on the clipboard.",
                    listOf(notifier.action("Copy", NotificationActionReceiver.COPY, model.id)),
                )
                status == "completed" -> {
                    val single = model.files.singleOrNull()?.uri
                    notifier.result(
                        model.id, "Received ${if (n == 1) "1 file" else "$n files"} from ${model.peerName}", "Saved to ${MediaStoreStorage.LABEL}",
                        if (single != null) listOf(notifier.activityAction("Open", model.id, openFileIntent(single))) else emptyList(),
                        tap = single?.let { notifier.activityIntent(model.id, openFileIntent(it)) },
                    )
                }
                status == "failed" -> notifier.result(
                    model.id, "Transfer from ${model.peerName} failed",
                    if (model.error == ErrorCode.CONNECTION_LOST.wire) "If it’s sent again, it continues where it stopped." else "Nothing incomplete was kept.",
                )
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
            everyoneOpen -> Triple("Receiving from everyone", "Visible to nearby devices as ${prefs.deviceName}", null)
            else -> Triple("Ready for your devices", "Only devices you paired can send to this phone", null)
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
            mode = if (!receivingEnabled) "off" else if (everyoneOpen) "everyone" else "mine",
            sharedText = sharedText,
            newestDeviceAt = newestDeviceAt,
            screenshotPermission = screenshots.hasPermission(),
        ))
    }

    fun openFileIntent(uri: String): Intent {
        val u = Uri.parse(uri)
        return Intent(Intent.ACTION_VIEW)
            .setDataAndType(u, app.contentResolver.getType(u) ?: "*/*")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    val isReceiving: Boolean get() = synchronized(lock) { receivingEnabled }

    /** Received links open only if they are plain web links; nothing else is launched. */
    private fun isWebLink(text: String): Boolean {
        val uri = runCatching { Uri.parse(text.trim()) }.getOrNull() ?: return false
        return (uri.scheme == "https" || uri.scheme == "http") && !uri.host.isNullOrBlank()
    }

    private fun linkIntent(text: String): Intent =
        Intent(Intent.ACTION_VIEW, Uri.parse(text.trim())).addCategory(Intent.CATEGORY_BROWSABLE).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    /** Opens a received link (http/https only). Returns false when it isn't one. */
    fun openLink(text: String): Boolean {
        if (!isWebLink(text)) return false
        return runCatching { app.startActivity(linkIntent(text)) }.isSuccess
    }

    fun copyText(text: String) {
        main.post { app.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText("CrossDrop", text)) }
    }

    val deviceId: String get() = identity.deviceId
    val fingerprint: String get() = identity.fingerprint

    companion object {
        const val APP_VERSION = "0.1.0"
        const val RECEIVE_AUTO_OFF_MS = 10 * 60 * 1000L
        /** Tried first so a paired device's remembered address stays valid; falls back to any port. */
        const val PREFERRED_PORT = 47100
        private const val TAG = "CrossDrop"

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
    val mode: String = "off",
    val sharedText: SharedText? = null,
    val newestDeviceAt: Long = 0,
    val screenshotPermission: Boolean = false,
)

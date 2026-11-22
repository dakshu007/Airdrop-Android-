package com.crossdrop.engine

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.crossdrop.MainActivity
import com.crossdrop.capture.CaptureActivity
import com.crossdrop.core.CaptureKind
import com.crossdrop.core.CaptureRequest
import com.crossdrop.core.CrossDropServer
import com.crossdrop.core.ErrorCode
import com.crossdrop.core.IncomingOffer
import com.crossdrop.core.IncomingTransfer
import com.crossdrop.core.LocalInfo
import com.crossdrop.core.OfferFile
import com.crossdrop.core.OfferKind
import com.crossdrop.core.OutgoingFile
import com.crossdrop.core.OutgoingTransfer
import com.crossdrop.core.PairingEvents
import com.crossdrop.core.PairingPrompt
import com.crossdrop.core.PeerInfo
import com.crossdrop.core.Platform
import com.crossdrop.core.Protocol
import com.crossdrop.core.ProtocolException
import com.crossdrop.core.QrPairing
import com.crossdrop.core.QrPairingClient
import com.crossdrop.core.ReceiverEvents
import com.crossdrop.core.Room
import com.crossdrop.core.RoomInvite
import com.crossdrop.core.RoomPairingClient
import com.crossdrop.core.Rooms
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
import com.crossdrop.queue.SendQueue
import com.crossdrop.rooms.RoomCodes
import com.crossdrop.screenshots.ScreenshotWatcher
import com.crossdrop.service.CrossDropService
import com.crossdrop.share.DirectShare
import com.crossdrop.share.SharedFile
import com.crossdrop.share.SharedFiles
import com.crossdrop.share.SharedText
import com.crossdrop.storage.ExpiringDrops
import com.crossdrop.storage.HistoryEntry
import com.crossdrop.storage.HistoryFile
import com.crossdrop.storage.HistoryRepository
import com.crossdrop.storage.MediaStoreStorage
import com.crossdrop.storage.PocketItem
import com.crossdrop.storage.PocketRepository
import com.crossdrop.storage.Prefs
import com.crossdrop.storage.TrustRepository
import com.crossdrop.tiles.ReceiveTileService
import com.crossdrop.widget.DevicesWidgetProvider
import java.io.File
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
    private val storage = MediaStoreStorage(app) { prefs.sortByType }
    /** "Send when nearby" queue (persistent). */
    val queue = SendQueue(app)
    /** Recent received files. */
    val pocket = PocketRepository(app)
    private val expiring = ExpiringDrops.get(app)
    /** Drip Rooms this phone is in (§9.9); shared by the server and outgoing transfers. In memory only. */
    val rooms = Rooms()
    private val network = NetworkMonitor(app, onNetworkAvailable = { onNetworkAvailable() }) { onNetworkChanged() }
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
    /** Capture requests from paired Macs waiting for a photo (§9.7). */
    private val captures = LinkedHashMap<String, PendingCapture>()
    /** The capture request the app should show (opened from its notification). */
    private var captureFocus: String? = null
    /** Text that just arrived from a paired Mac, offered for pasting for two minutes. */
    private var clip: Clip? = null
    /** A device picked on the home-screen widget: the UI opens the file picker for it. */
    private var pendingTarget: String? = null
    private var pendingTargetAt = 0L
    /** End of the short discovery window that looks for devices with queued sends. */
    private var queueWindowUntil = 0L
    /** The room this phone hosts (shows the code for), and its invite. */
    private var roomHosting: String? = null
    private var roomInvite: String? = null
    /** Receiving was switched on only for the room; it goes off again when the room ends. */
    private var roomStartedReceiving = false

    class PairingEntry(val prompt: PairingPrompt, var waitingForPeer: Boolean)
    private class SendRequest(
        val deviceId: String,
        val files: List<SharedFile>,
        val text: SharedText? = null,
        val expiresAfter: Long? = null,
        val queueId: String? = null,
        val requestId: String? = null,
        val targets: List<Endpoint>? = null,
    )
    class Endpoint(val host: String, val port: Int, val name: String, val platform: String)

    class PendingCapture(
        val requestId: String,
        val kind: CaptureKind,
        val peerId: String,
        val peerName: String,
        val replyHost: String,
        val replyPort: Int?,
        val expiresAt: Long,
        /** "open", or "sending" while the answer is on its way. */
        var state: String = "open",
        /** The camera / picker was opened for it: no more heads-up notifications. */
        var opened: Boolean = false,
    )

    class Clip(val transferId: String, val from: String, val fromPlatform: String, val text: String, val expiresAt: Long)

    private val screenshots = ScreenshotWatcher(app) { uri, name -> onScreenshot(uri, name) }
    /** Experimental no-router mode (see HotspotManager). */
    val hotspot = com.crossdrop.hotspot.HotspotManager(app) { onNetworkChanged() }

    /** Receives a full snapshot JSON whenever state changes (coalesced, main thread). */
    var snapshotListener: ((String) -> Unit)? = null
    private var publishPending = false
    private var lastTileState = false

    init {
        // Drip Rooms live in memory only, so a room from before a restart can't come back:
        // its temporary trust (with no room, banner or "Leave" left to end it) goes now.
        trust.forgetAllTemporary()
        trust.onChange = {
            publishDirectShare()
            // Home-screen widget: redrawn (coalesced) when paired devices change.
            main.removeCallbacksAndMessages(WIDGET_TOKEN)
            main.postDelayed({ DevicesWidgetProvider.refresh(app) }, WIDGET_TOKEN, 500)
            changed()
        }
        network.start()
        main.post {
            restoreReceiving()
            updateScreenshotWatcher()
        }
        // App start: delete expiring drops that are due, and look for devices with queued sends.
        purgeExpiredDrops()
        main.postDelayed({ openQueueWindow() }, QUEUE_START_DELAY_MS)
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
        advertiser.register(prefs.deviceName, port, identity.deviceId, private = privateMode(), roomHints = rooms.hints())
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
            // Rooms are shared with outgoing transfers; Turbo joins are always accepted (§9.10).
            val s = CrossDropServer(identity, { localInfo }, trust, storage, receiverEvents, { privateMode() }, rooms, { true })
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
            roomStartedReceiving = false
            receivingPort = null
            autoOffAt = null
            receivingError = null
            server.also { server = null }
        }
        main.removeCallbacks(autoOff)
        advertiser.unregister()
        s?.stop() // In-flight inbound transfers keep their own connections.
        // Discovery (the UI's, or a "send when nearby" window) still needs the multicast lock.
        if (!synchronized(lock) { discoveryWanted } && !queueWindowOpen()) network.setMulticast(false)
        changed()
        CrossDropService.update(app)
    }

    private val autoOff = Runnable {
        val busy = synchronized(lock) { incoming.isNotEmpty() || offers.isNotEmpty() || pairing.isNotEmpty() }
        when {
            busy -> scheduleAutoOff(60_000)
            // The "everyone" window closes; paired devices can still reach this phone.
            prefs.receiveBase == "mine" -> setReceiveMode("mine")
            // In a Drip Room: stay reachable for its members (privately) until it ends.
            rooms.active().isNotEmpty() -> {
                synchronized(lock) { everyoneOpen = false; autoOffAt = null; roomStartedReceiving = true }
                advertise()
                changed()
            }
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
        val keepForQueue = queueWindowOpen()
        synchronized(lock) {
            discoveryWanted = false
            if (!keepForQueue) nearby.clear()
        }
        // A "send when nearby" window keeps browsing until it closes (at most a minute).
        if (keepForQueue) {
            changed()
            return
        }
        discovery.stop()
        if (!synchronized(lock) { receivingEnabled }) network.setMulticast(false)
        changed()
    }

    private fun queueWindowOpen(): Boolean = synchronized(lock) { queueWindowUntil > System.currentTimeMillis() }

    /** True when the device says it is in one of this phone's Drip Rooms (a hint; pairing proves it). */
    private fun inRoom(d: DiscoveredDevice): Boolean = d.roomHints.any { rooms.forHint(it) != null }

    private fun onDeviceFound(d: DiscoveredDevice) {
        // "My devices only" receivers are listed only for devices that already paired with
        // them, or that say they are in one of this phone's Drip Rooms (§9.9).
        if (d.private && trust.get(d.deviceId) == null && !inRoom(d)) return
        val isNew: Boolean
        synchronized(lock) {
            nearby.values.removeAll { it.serviceName == d.serviceName && it.deviceId != d.deviceId }
            isNew = nearby.put(d.deviceId, d) == null
        }
        if (isNew) synchronized(lock) { newestDeviceAt = System.currentTimeMillis() }
        changed()
        val direct = synchronized(lock) { pendingDirect?.takeIf { it.deviceId == d.deviceId }?.also { pendingDirect = null } }
        if (direct != null) workers.execute { runCatching { send(direct.deviceId, direct.files) }.onSuccess { clearShared() } }
        // Queued "send when nearby" items for this device go now.
        if (d.deviceId in queue.waitingDevices()) workers.execute { deliverQueued(d.deviceId, force = false) }
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
            if (recv && port != null && (network.localNetwork || hotspot.isOn)) advertise()
            if (disc || queueWindowOpen()) {
                discovery.stop()
                synchronized(lock) { nearby.clear() }
                if (network.localNetwork || hotspot.isOn) discovery.start()
            }
            changed()
        }
    }

    /** A Wi-Fi / Ethernet network came up (also a switch between networks): try queued sends shortly. */
    private fun onNetworkAvailable() {
        // Called on the system's network thread, possibly while the engine is still being
        // built: only touch [main] here. Debounced with a token; the work runs on main later.
        main.removeCallbacksAndMessages(NETWORK_TOKEN)
        // Give the new network a moment to get an address before connecting.
        main.postDelayed({
            // Re-announce on the new network (the address changed even if "connected" did not).
            val (recv, port) = synchronized(lock) { receivingEnabled to receivingPort }
            if (recv && port != null) advertise()
            openQueueWindow()
        }, NETWORK_TOKEN, NETWORK_SETTLE_MS)
    }

    // ---------------------------------------------------------------- send when nearby (queue)

    /**
     * Looks for devices with queued sends: one direct try at each one's last known address,
     * and a discovery window of [QUEUE_WINDOW_MS]. Runs at app start and when Wi-Fi changes;
     * never on a timer, so the phone is not scanning while idle.
     */
    fun openQueueWindow() {
        val devices = queue.waitingDevices()
        if (devices.isEmpty() || !(network.localNetwork || hotspot.isOn)) return
        workers.execute { devices.forEach { deliverQueued(it, force = true) } }
        synchronized(lock) { queueWindowUntil = System.currentTimeMillis() + QUEUE_WINDOW_MS }
        network.setMulticast(true)
        discovery.start()
        main.removeCallbacks(closeQueueWindow)
        main.postDelayed(closeQueueWindow, QUEUE_WINDOW_MS)
        changed()
    }

    private val closeQueueWindow = Runnable {
        val (wanted, recv) = synchronized(lock) {
            queueWindowUntil = 0
            discoveryWanted to receivingEnabled
        }
        if (!wanted) {
            discovery.stop()
            synchronized(lock) { nearby.clear() }
            if (!recv) network.setMulticast(false)
        }
        changed()
    }

    /**
     * Starts the next waiting item for [deviceId] if the device can be reached (discovered,
     * or at its last address). One item at a time per device; the next one starts when it
     * finishes. [force]: ignore the short back-off after a recent try (a new network).
     */
    private fun deliverQueued(deviceId: String, force: Boolean) {
        if (trust.get(deviceId) == null) return // Forgotten (or room trust ended): it waits, the user can cancel.
        val busy = queue.all().any { it.deviceId == deviceId && it.status == "sending" }
        if (busy) return
        val now = System.currentTimeMillis()
        val next = queue.waitingFor(deviceId).firstOrNull {
            force || it.lastTriedAt == null || now - it.lastTriedAt >= QUEUE_RETRY_BACKOFF_MS
        } ?: return
        if (endpoint(deviceId) == null) return
        val item = queue.claim(next.id) ?: return
        try {
            val transferId = when (item.kind) {
                "files" -> send(deviceId, item.files.map { it.toShared() }, item.expiresAfter, queueId = item.id)
                else -> sendText(deviceId, SharedText(item.kind, item.text ?: ""), queueId = item.id)
            }
            // The transfer may already have ended (and moved the item on) before this line.
            queue.update(item.id) { if (it.status == "sending") it.copy(transferId = transferId) else it }
        } catch (e: IllegalStateException) {
            queue.update(item.id) { it.copy(status = "waiting", transferId = null) }
        } catch (e: Exception) {
            queue.update(item.id) { it.copy(status = "failed", error = ErrorCode.FILE_UNREADABLE.wire, transferId = null) }
        }
        changed()
    }

    /** Queues files for a paired device that isn't reachable now. Blocking (may copy). Returns the queue id. */
    fun queueFiles(deviceId: String, files: List<SharedFile>, expiresAfter: Long?): String {
        if (trust.get(deviceId) == null) throw IllegalStateException("not_paired")
        val item = queue.addFiles(deviceId, files, expiresAfter)
        changed()
        workers.execute { deliverQueued(deviceId, force = true) }
        return item.id
    }

    /** Queues the shared link / text for a paired device. Returns the queue id. */
    fun queueSharedText(deviceId: String): String {
        if (trust.get(deviceId) == null) throw IllegalStateException("not_paired")
        val text = synchronized(lock) { sharedText } ?: throw IllegalStateException("nothing to send")
        val item = queue.addText(deviceId, text.kind, text.text)
        changed()
        workers.execute { deliverQueued(deviceId, force = true) }
        return item.id
    }

    /** Removes a queued item (cancelling its transfer if one is running) and CrossDrop's copies. */
    fun cancelQueued(queueId: String) {
        val item = queue.get(queueId) ?: return
        queue.remove(queueId)
        item.transferId?.let { cancel(it) }
        changed()
    }

    /** "Try again" for a failed queued item: it waits again and goes as soon as the device is reachable. */
    fun retryQueued(queueId: String) {
        val item = queue.update(queueId) { if (it.status == "failed") it.copy(status = "waiting", error = null, lastTriedAt = null) else it } ?: return
        changed()
        workers.execute { deliverQueued(item.deviceId, force = true) }
        if (endpoint(item.deviceId) == null) main.post { openQueueWindow() }
    }

    /** A queued item's transfer ended: done, back to waiting (not reachable), or failed. */
    private fun onQueuedTransferFinished(queueId: String, deviceId: String, status: String, error: String?, triedHost: String?) {
        val retryable = error != null && error in RETRYABLE
        when {
            status == "completed" -> queue.remove(queueId)
            // The user cancelled the transfer itself: they don't want it sent.
            status == "cancelled" -> queue.remove(queueId)
            status == "failed" && retryable -> queue.update(queueId) { it.copy(status = "waiting", transferId = null) }
            status == "rejected" -> queue.update(queueId) { it.copy(status = "failed", error = "rejected", transferId = null) }
            else -> queue.update(queueId) { it.copy(status = "failed", error = error ?: ErrorCode.INTERNAL.wire, transferId = null) }
        }
        changed()
        // Next item for the device, or one more try if discovery found it at another address.
        val nearbyHost = synchronized(lock) { nearby[deviceId]?.host }
        val force = status == "failed" && retryable && nearbyHost != null && nearbyHost != triedHost
        if (status == "completed" || force) workers.execute { deliverQueued(deviceId, force = force) }
    }

    // ---------------------------------------------------------------- sending

    /** Where a device can be reached: its discovered address, else the last one that worked (§9.5). */
    private fun endpoint(deviceId: String): Endpoint? {
        synchronized(lock) { nearby[deviceId] }?.let { return Endpoint(it.host, it.port, it.name, it.platform.wire) }
        val peer = trust.get(deviceId) ?: return null
        val (host, port) = trust.lastAddress(deviceId) ?: return null
        return Endpoint(host, port, peer.name, peer.platform.wire)
    }

    /**
     * Starts sending [files] to a nearby or remembered device. Returns the transfer id.
     * [expiresAfter]: ask the receiver to delete them after that many seconds (§9.8).
     * [requestId] / [targets]: the answer to a capture request (§9.7), sent to the
     * requester's address first.
     */
    fun send(
        deviceId: String,
        files: List<SharedFile>,
        expiresAfter: Long? = null,
        queueId: String? = null,
        requestId: String? = null,
        targets: List<Endpoint>? = null,
    ): String {
        require(files.isNotEmpty()) { "no files" }
        require(expiresAfter == null || expiresAfter in Protocol.MIN_EXPIRES_AFTER..Protocol.MAX_EXPIRES_AFTER) { "bad expiresAfter" }
        val outgoingFiles = files.map { f ->
            OutgoingFile(f.name, f.size, f.mime, f.path) {
                app.contentResolver.openInputStream(Uri.parse(f.uri)) ?: throw FileNotFoundException("unreadable")
            }
        }
        // Hand the URIs to the service so the read grant outlives the activity.
        return start(deviceId, SendRequest(deviceId, files, null, expiresAfter, queueId, requestId, targets), OfferKind.FILES, outgoingFiles,
            files.map { FileModel((it.path + it.name).joinToString("/"), it.size ?: 0, it.mime) },
            files.map { Uri.parse(it.uri) }.filter { it.scheme == "content" })
    }

    /** Sends a link or text (§9.2); it opens or lands on the clipboard there, and is never saved as a file. */
    fun sendText(deviceId: String, text: SharedText, queueId: String? = null): String {
        val kind = if (text.kind == "link") OfferKind.LINK else OfferKind.TEXT
        val name = if (kind == OfferKind.LINK) "Link" else "Text"
        val file = OutgoingFile.text(name, text.text)
        val id = start(deviceId, SendRequest(deviceId, emptyList(), text, queueId = queueId), kind, listOf(file),
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

    /** The Drip Room a discovered device says it shares with this phone, if any (§9.9). */
    private fun roomFor(deviceId: String): Room? {
        val d = synchronized(lock) { nearby[deviceId] } ?: return null
        return d.roomHints.firstNotNullOfOrNull { rooms.forHint(it) }
    }

    private fun start(
        deviceId: String,
        request: SendRequest,
        kind: OfferKind,
        outgoingFiles: List<OutgoingFile>,
        models: List<FileModel>,
        grants: List<Uri>,
    ): String {
        // Usually one address; a capture answer tries the requester's address, then discovery / the last one.
        val candidates = request.targets?.takeIf { it.isNotEmpty() } ?: listOfNotNull(endpoint(deviceId))
        val target = candidates.firstOrNull() ?: throw IllegalStateException("unreachable")
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
        model.expiresAfter = request.expiresAfter
        model.queueId = request.queueId
        model.captureRequestId = request.requestId
        model.targetHost = target.host
        synchronized(lock) {
            transfers[id] = model
            sendRequests[id] = request
        }
        CrossDropService.update(app, grants)

        // An untrusted member of a shared Drip Room pairs by proving the room key (§9.9).
        val room = if (trust.get(deviceId) == null) roomFor(deviceId) else null
        // Turbo (experimental, §9.10): ask for parallel connections for several files.
        val turbo = if (prefs.turbo && kind == OfferKind.FILES && outgoingFiles.size >= 2) Protocol.MAX_TURBO_STREAMS else 1
        fun transferTo(ep: Endpoint) = OutgoingTransfer(
            identity, localInfo, trust, ep.host, ep.port, deviceId, outgoingFiles, SendEvents(model, ep), id, kind,
            requestId = request.requestId,
            expiresAfter = request.expiresAfter,
            room = room,
            turbo = turbo,
        )
        val first = transferTo(target)
        synchronized(lock) { outgoing[id] = first }
        changed()

        workers.execute {
            var transfer = first
            var index = 0
            while (true) {
                try {
                    val peer = transfer.run()
                    prefs.lastDeviceId = peer.deviceId
                    val ep = candidates[index]
                    trust.rememberAddress(peer.deviceId, ep.host, ep.port)
                    update(model, publish = false) { streams = transfer.streams }
                    finish(model, "completed", null, null, peer)
                } catch (e: TransferRejectedException) {
                    finish(model, "rejected", null, e.reason, null)
                } catch (e: ProtocolException) {
                    // Nothing was sent when the connection could not even open: try the next address.
                    if (e.code == ErrorCode.UNREACHABLE && index + 1 < candidates.size && !transfer.isCancelled) {
                        index++
                        val next = transferTo(candidates[index])
                        val swapped = synchronized(lock) {
                            if (outgoing[id] === transfer) {
                                outgoing[id] = next
                                model.targetHost = candidates[index].host
                                true
                            } else {
                                false
                            }
                        }
                        if (swapped) {
                            transfer = next
                            continue
                        }
                    }
                    if (e.code == ErrorCode.CANCELLED) finish(model, "cancelled", e, null, null)
                    else finish(model, "failed", e, null, null)
                } catch (e: Exception) {
                    finish(model, "failed", ProtocolException(ErrorCode.INTERNAL, e.javaClass.simpleName), null, null)
                }
                break
            }
        }
        return id
    }

    fun retry(transferId: String): String {
        val req = synchronized(lock) { sendRequests[transferId] } ?: throw IllegalStateException("not retryable")
        val newId = if (req.text != null) {
            sendText(req.deviceId, req.text)
        } else {
            send(req.deviceId, req.files, req.expiresAfter, requestId = req.requestId, targets = req.targets)
        }
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
            heartbeat(model, total)
            changedThrottled()
        }

        override fun onPairingPrompt(prompt: PairingPrompt) = addPairing(prompt)
        override fun onPairingWaitingForPeer(prompt: PairingPrompt) = pairingWaiting(prompt)
    }

    /** Haptic heartbeat: one light tick each time a transfer passes another 10% (not at 0 or 100). */
    private fun heartbeat(model: TransferModel, done: Long) {
        val total = model.totalBytes
        if (total <= 0) return
        val decile = (done * 10 / total).toInt()
        val tick = synchronized(lock) {
            if (decile in 1..9 && decile > model.lastDecile) {
                model.lastDecile = decile
                true
            } else {
                false
            }
        }
        if (tick) feedback.heartbeat()
    }

    fun cancel(transferId: String) {
        val (out, inc) = synchronized(lock) { outgoing[transferId] to incoming[transferId] }
        if (out != null) workers.execute { out.cancel() }
        if (inc != null) workers.execute { inc.cancel() }
    }

    fun dismiss(transferId: String) {
        val capture = synchronized(lock) {
            val t = transfers[transferId] ?: return
            if (!t.isFinished) return
            transfers.remove(transferId)
            sendRequests.remove(transferId)
            // A failed capture answer kept its photo for Retry; an open request still owns it.
            t.captureRequestId?.takeIf { t.direction == "outgoing" && !captures.containsKey(it) }
        }
        capture?.let { releaseCaptureFiles(it) }
        changed()
    }

    // ---------------------------------------------------------------- foreground

    /** True while CrossDrop is on screen; requests then show in the app, not as heads-up notifications. */
    @Volatile
    private var appVisible = false

    fun setAppVisible(visible: Boolean) {
        appVisible = visible
        val (prompts, pending) = synchronized(lock) { pairing.values.map { it.prompt } to offers.values.toList() }
        val now = System.currentTimeMillis()
        // Capture requests: all of them (to cancel), and those still waiting for an answer (to re-post).
        val (asks, waiting) = synchronized(lock) {
            captures.values.toList() to captures.values.filter { it.state == "open" && !it.opened && it.expiresAt > now }
        }
        if (visible) {
            prompts.forEach { notifier.cancel(it.sessionId) }
            pending.forEach { notifier.cancel(it.transferId) }
            asks.forEach { notifier.cancel(captureNotificationId(it.requestId)) }
        } else {
            // Leaving the app with a decision pending: make sure it can still be found.
            prompts.forEach(::notifyPairing)
            pending.forEach(::notifyOffer)
            // Not for a request whose camera / picker is what covers the app now.
            waiting.forEach { notifyCapture(it) }
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
            model.expiresAfter = transfer.expiresAfter
            model.captureRequestId = transfer.requestId
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
                streams = transfer.streams
            }
            heartbeat(model, totalBytes)
            changedThrottled()
        }

        override fun onFileSaved(transfer: IncomingTransfer, fileIndex: Int, saved: SavedFile) {
            val model = synchronized(lock) { transfers[transfer.transferId] } ?: return
            update(model) { files[fileIndex] = files[fileIndex].copy(name = saved.displayName, uri = saved.location) }
        }

        override fun onCompleted(transfer: IncomingTransfer) {
            val model = synchronized(lock) { transfers[transfer.transferId] } ?: return
            update(model, publish = false) { streams = transfer.streams }
            finish(model, "completed", null, null, transfer.peer)
        }

        override fun onCaptureRequest(peer: PeerInfo, request: CaptureRequest): Boolean = onCapture(peer, request)

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
        // A Drip Room code (§9.9) from the same scanner: join the room; returns the room's name.
        if (raw.trim().startsWith(RoomInvite.PREFIX)) return joinRoom(raw).first
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

    // ---------------------------------------------------------------- capture requests (§9.7)

    /**
     * A paired Mac asks for a photo. Accepted only when the user will see it: CrossDrop
     * is on screen (the request shows there), or the notification was posted. Only
     * permanent pairings may ask; temporary Drip Room trust (§9.9) can't.
     */
    private fun onCapture(peer: PeerInfo, request: CaptureRequest): Boolean {
        val trusted = trust.get(peer.deviceId)?.takeIf { it.expiresAt == null } ?: return false
        val entry = PendingCapture(
            request.requestId, request.kind, peer.deviceId, trusted.name,
            request.replyHost, request.replyPort, System.currentTimeMillis() + Protocol.CAPTURE_REQUEST_TTL_MS,
        )
        synchronized(lock) {
            if (captures.size >= MAX_CAPTURES && !captures.containsKey(request.requestId)) return false
            captures[request.requestId] = entry
        }
        // On screen the app shows the request itself; no heads-up on top of it.
        val shown = appVisible || notifyCapture(entry)
        if (!shown) {
            synchronized(lock) { captures.remove(request.requestId) }
            return false
        }
        main.postDelayed({ endCapture(request.requestId) }, Protocol.CAPTURE_REQUEST_TTL_MS)
        changed()
        return true
    }

    private fun notifyCapture(c: PendingCapture): Boolean {
        val title = if (c.kind == CaptureKind.PHOTO) "${c.peerName} wants a photo" else "${c.peerName} wants photos"
        val tap = notifier.activityIntent(
            "capture-open:${c.requestId}",
            Intent(app, MainActivity::class.java)
                .setAction(MainActivity.ACTION_CAPTURE)
                .putExtra(MainActivity.EXTRA_REQUEST_ID, c.requestId)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        )
        val take = notifier.activityAction(
            "Take photo", "capture-photo:${c.requestId}",
            CaptureActivity.intent(app, c.requestId, CaptureActivity.MODE_PHOTO).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        val pick = notifier.activityAction(
            "Pick photo", "capture-pick:${c.requestId}",
            CaptureActivity.intent(app, c.requestId, CaptureActivity.MODE_PICK).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        val actions = if (c.kind == CaptureKind.PHOTO) listOf(take, pick) else listOf(pick, take)
        return notifier.capture(
            captureNotificationId(c.requestId), title, "It goes straight back to ${c.peerName} once you take or pick one.",
            tap, actions, (c.expiresAt - System.currentTimeMillis()).coerceAtLeast(1_000),
        )
    }

    fun hasCaptureRequest(requestId: String): Boolean = synchronized(lock) { captures[requestId]?.takeIf { it.expiresAt > System.currentTimeMillis() } != null }

    /** Opened from the notification: the app shows its capture screen for this request. */
    fun focusCapture(requestId: String) {
        synchronized(lock) { captureFocus = requestId.takeIf { captures.containsKey(it) } }
        changed()
    }

    fun clearCaptureFocus() {
        synchronized(lock) { captureFocus = null }
        changed()
    }

    /** The camera or picker opened for [requestId]: its notification goes, and doesn't come back. */
    fun openedCapture(requestId: String) {
        synchronized(lock) { captures[requestId]?.opened = true }
        notifier.cancel(captureNotificationId(requestId))
    }

    /**
     * The camera or picker closed without an answer: the request is open again. If CrossDrop
     * isn't on screen a moment later (where the request shows), its notification comes back.
     */
    fun closedCapture(requestId: String) {
        synchronized(lock) { captures[requestId]?.opened = false }
        main.postDelayed({
            if (!appVisible) {
                val now = System.currentTimeMillis()
                val c = synchronized(lock) { captures[requestId]?.takeIf { it.state == "open" && !it.opened && it.expiresAt > now } }
                if (c != null) notifyCapture(c)
            }
        }, CAPTURE_RENOTIFY_DELAY_MS)
    }

    /** The user said no (or it expired): forget the request and any photo taken for it. The Mac is not told. */
    fun declineCapture(requestId: String) = endCapture(requestId)

    private fun endCapture(requestId: String) {
        val removed = synchronized(lock) {
            val c = captures[requestId] ?: return
            // A request whose answer is on its way ends when that transfer does, even past its
            // time: the photo is still being read (onCaptureAnswerFinished ends it).
            if (c.state == "sending") return
            captures.remove(requestId)
            if (captureFocus == requestId) captureFocus = null
            c
        }
        notifier.cancel(captureNotificationId(removed.requestId))
        releaseCaptureFiles(requestId)
        changed()
    }

    /**
     * Deletes the photo taken for [requestId] unless something still reads it: an answer
     * on its way, or a failed one that can still be retried (it goes when dismissed).
     */
    private fun releaseCaptureFiles(requestId: String) {
        val inUse = synchronized(lock) {
            captures[requestId]?.state == "sending" || transfers.values.any {
                it.direction == "outgoing" && it.captureRequestId == requestId && (!it.isFinished || it.canRetry)
            }
        }
        if (!inUse) File(app.cacheDir, "capture/$requestId").deleteRecursively()
    }

    /**
     * Sends [files] back to the device that asked (§9.7), with its requestId so it is
     * accepted without a prompt there. Goes to the address the request came from, then
     * wherever discovery or the last address says the Mac is.
     */
    fun answerCapture(requestId: String, files: List<SharedFile>) {
        val c = synchronized(lock) { captures[requestId] } ?: run {
            notifier.result("capture-failed", "Couldn’t send the photo", "The request expired. Ask again from the Mac.")
            return
        }
        val targets = ArrayList<Endpoint>()
        c.replyPort?.let { targets.add(Endpoint(c.replyHost, it, c.peerName, Platform.MACOS.wire)) }
        endpoint(c.peerId)?.let { ep -> if (targets.none { it.host == ep.host && it.port == ep.port }) targets.add(ep) }
        if (targets.isEmpty()) {
            notifier.result("capture-failed", "Couldn’t reach ${c.peerName}", "Make sure both devices are on the same Wi-Fi, then try again.")
            return
        }
        try {
            synchronized(lock) {
                c.state = "sending"
                if (captureFocus == requestId) captureFocus = null
            }
            notifier.cancel(captureNotificationId(requestId))
            send(c.peerId, files, requestId = requestId, targets = targets)
        } catch (e: Exception) {
            synchronized(lock) { c.state = "open" }
            notifier.result("capture-failed", "Couldn’t send the photo", "Open CrossDrop to try again.")
        }
        changed()
    }

    /**
     * The answer's transfer ended: done (or the request ran out meanwhile) ends the request;
     * otherwise it is open again (answer again from the app, or Retry the transfer).
     */
    private fun onCaptureAnswerFinished(requestId: String, status: String) {
        val now = System.currentTimeMillis()
        val end = synchronized(lock) {
            val c = captures[requestId]
            c?.state = "open"
            c == null || status == "completed" || c.expiresAt <= now
        }
        if (end) {
            endCapture(requestId)
            // Also when the request was gone already; kept while the transfer can be retried.
            releaseCaptureFiles(requestId)
        } else {
            changed()
        }
    }

    // ---------------------------------------------------------------- clipboard pill

    /** Text from a paired Mac: "Paste from <Mac>" for two minutes, in the app and as a notification. */
    private fun offerClip(model: TransferModel, text: String) {
        val c = Clip(model.id, model.peerName, model.peerPlatform, text, System.currentTimeMillis() + CLIP_TTL_MS)
        synchronized(lock) { clip = c }
        main.removeCallbacks(clearClip)
        main.postDelayed(clearClip, CLIP_TTL_MS)
        if (!appVisible) {
            notifier.clip(
                model.id, "Paste from ${model.peerName}", "Tap Copy to put it on this phone’s clipboard.",
                notifier.action("Copy", NotificationActionReceiver.COPY, model.id), CLIP_TTL_MS,
            )
        }
    }

    private val clearClip = Runnable {
        val id = synchronized(lock) { clip?.transferId.also { clip = null } }
        if (id != null) notifier.cancel(id)
        changed()
    }

    /** Copies the latest clip to the clipboard. False when it has expired. */
    fun copyClip(): Boolean {
        val c = synchronized(lock) { clip?.takeIf { it.expiresAt > System.currentTimeMillis() } } ?: return false
        copyText(c.text)
        notifier.cancel(c.transferId)
        return true
    }

    fun dismissClip() {
        main.removeCallbacks(clearClip)
        clearClip.run()
    }

    // ---------------------------------------------------------------- Drip Rooms (§9.9)

    /** Pairing callbacks that show a code comparison in the app if a room proof isn't accepted. */
    private val roomPairingEvents = object : PairingEvents {
        override fun onPairingPrompt(prompt: PairingPrompt) = addPairing(prompt)
        override fun onPairingWaitingForPeer(prompt: PairingPrompt) = pairingWaiting(prompt)
        override fun onPairingClosed(prompt: PairingPrompt, paired: Boolean) = removePairing(prompt)
    }

    /** Receiving must be on for room members to reach this phone; privately unless the user chose more. */
    private fun ensureReceivingForRoom() {
        if (isReceiving) return
        synchronized(lock) { roomStartedReceiving = true }
        startReceiving()
    }

    /** Blocking: waits (bounded) for the listener to be up. */
    private fun awaitPort(timeoutMs: Long): Int? {
        val until = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < until) {
            synchronized(lock) { receivingPort }?.let { return it }
            if (!isReceiving) return null
            Thread.sleep(100)
        }
        return synchronized(lock) { receivingPort }
    }

    /**
     * Hosts a room for [minutes] (30, 60, 120 or 240). Blocking. Returns the invite
     * (`crossdrop://room?...`) the QR code shows. Ends any room this phone was in.
     */
    fun startRoom(name: String, minutes: Int): String {
        require(minutes in ROOM_MINUTES) { "bad_duration" }
        leaveRoom()
        ensureReceivingForRoom()
        val port = awaitPort(5_000) ?: throw IllegalStateException("not_receiving")
        val hosts = RoomCodes.localAddresses().ifEmpty { throw IllegalStateException("no_network") }
        val room = rooms.create(name.trim().ifEmpty { "${prefs.deviceName}’s room" }, minutes * 60L)
        val invite = RoomInvite(room, hosts, port, identity.fingerprint).toUri()
        synchronized(lock) {
            roomHosting = room.id
            roomInvite = invite
        }
        scheduleRoomEnd(room)
        advertise()
        changed()
        return invite
    }

    /**
     * Joins the room in a scanned code and pairs with the device that showed it (by room
     * proof; falls back to comparing codes in the app). Blocking. Returns the room name
     * and the host's name (null when it could not be reached; others are found nearby).
     */
    fun joinRoom(raw: String): Pair<String, String?> {
        val invite = RoomInvite.parse(raw.trim()) ?: throw IllegalArgumentException("bad_code")
        if (invite.fingerprint == identity.fingerprint) throw IllegalArgumentException("own_code")
        leaveRoom()
        if (!rooms.join(invite.room)) throw IllegalArgumentException("expired")
        synchronized(lock) {
            roomHosting = null
            roomInvite = null
        }
        ensureReceivingForRoom()
        scheduleRoomEnd(invite.room)
        advertise()
        changed()
        var hostName: String? = null
        for (host in invite.hosts) {
            try {
                val peer = RoomPairingClient.pairOnly(identity, localInfo, trust, invite.copy(hosts = listOf(host)), roomPairingEvents)
                trust.rememberAddress(peer.deviceId, host, invite.port)
                hostName = trust.get(peer.deviceId)?.name ?: peer.name
                break
            } catch (e: ProtocolException) {
                if (e.code != ErrorCode.UNREACHABLE) break
            }
        }
        changed()
        return invite.room.name to hostName
    }

    /**
     * Leaves (or, when hosting, ends) the room, also when it ran out. This phone's trust from
     * the room ends now too. Members are not told; they keep the room among themselves.
     */
    fun leaveRoom() {
        rooms.leaveAll()
        // This phone is in at most one room, so all temporary trust is that room's (also
        // trust that kept an older, longer end time from an earlier room).
        trust.forgetAllTemporary()
        val stop = synchronized(lock) {
            roomHosting = null
            roomInvite = null
            roomStartedReceiving.also { roomStartedReceiving = false } && !everyoneOpen
        }
        main.removeCallbacks(roomEnd)
        if (stop && prefs.receiveBase == "off") stopReceiving() else advertise()
        // Always: a room that ran out is already gone from rooms.active(), but the UI still shows it.
        changed()
    }

    private val roomEnd = Runnable { leaveRoom() }

    private fun scheduleRoomEnd(room: Room) {
        main.removeCallbacks(roomEnd)
        main.postDelayed(roomEnd, (room.expiresAtMillis - System.currentTimeMillis()).coerceAtLeast(0))
    }

    /** The hosted room's QR code as a base64 PNG, or null when not hosting. */
    fun roomQrPng(sizePx: Int): String? {
        val invite = synchronized(lock) { roomInvite } ?: return null
        return RoomCodes.qrPng(invite, sizePx)
    }

    // ---------------------------------------------------------------- Pocket and widget target

    fun pocketItem(id: String): PocketItem? = pocket.get(id)

    /** Removes an item from the Pocket; with [deleteFile], also deletes the saved file (only CrossDrop's own). */
    fun removePocketItem(id: String, deleteFile: Boolean): Boolean {
        val item = pocket.get(id) ?: return false
        if (deleteFile && !MediaStoreStorage.delete(app, item.uri)) return false
        pocket.remove(id)
        changed()
        return true
    }

    /** Re-share through the Android share sheet, with a read grant for the chosen app only. */
    fun shareIntent(item: PocketItem): Intent {
        val uri = Uri.parse(item.uri)
        val send = Intent(Intent.ACTION_SEND)
            .setType(item.mime ?: app.contentResolver.getType(uri) ?: "*/*")
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        send.clipData = ClipData.newRawUri(item.name, uri)
        return Intent.createChooser(send, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }

    /** True when CrossDrop confirmed deleting every expiring file of [transferId] (§9.8). */
    fun isDropDeleted(transferId: String): Boolean = expiring.isDeleted(transferId)

    /** Expiring drops that were deleted: drop them from the Pocket. */
    fun onDropsDeleted(uris: List<String>) {
        pocket.removeUris(uris)
        changed()
    }

    /** Deletes expiring drops that are due (app start, service start; the alarm does the rest). */
    fun purgeExpiredDrops() {
        workers.execute {
            val gone = expiring.purgeDue()
            if (gone.isNotEmpty()) onDropsDeleted(gone)
        }
    }

    /** A device chosen on the home-screen widget; the UI reads it from the snapshot and opens the picker. */
    fun setPendingTarget(deviceId: String) {
        if (trust.get(deviceId) == null) return
        synchronized(lock) {
            pendingTarget = deviceId
            pendingTargetAt = System.currentTimeMillis()
        }
        changed()
    }

    fun clearPendingTarget() {
        synchronized(lock) { pendingTarget = null }
        changed()
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
        val text = synchronized(lock) { clip?.takeIf { it.transferId == transferId }?.text ?: transfers[transferId]?.text } ?: return
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
        workers.execute { DirectShare.publish(app, trust.permanent()) }
    }

    fun forget(deviceId: String) = trust.forget(deviceId)

    fun setAutoAccept(deviceId: String, enabled: Boolean) = trust.setAutoAccept(deviceId, enabled)

    fun setDeviceName(name: String) {
        prefs.deviceName = name
        advertise() // Keeps "My devices only" and room hints as they are.
        changed()
    }

    /** Known keys: 'sound', 'haptics', 'welcomed'. Unknown keys are ignored. */
    fun setPreference(key: String, value: Boolean) {
        when (key) {
            "sound" -> prefs.sound = value
            "haptics" -> prefs.haptics = value
            "welcomed" -> prefs.welcomed = value
            "sortByType" -> prefs.sortByType = value
            "turbo" -> prefs.turbo = value
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
        val now = System.currentTimeMillis()
        // A queued send that just could not reach the device goes back to waiting quietly.
        val requeue = model.queueId != null && status == "failed" && error != null && error.code.wire in RETRYABLE
        synchronized(lock) {
            model.status = status
            model.error = error?.let { it.code.wire }
            model.rejectReason = rejectReason
            model.updatedAt = now
            model.canRetry = model.direction == "outgoing" && (status == "failed" || status == "cancelled") &&
                sendRequests.containsKey(model.id) && model.queueId == null
            if (status == "completed") model.bytesTransferred = model.totalBytes
            val expiresAfter = model.expiresAfter
            if (expiresAfter != null && status == "completed") model.deleteAt = now + expiresAfter * 1000
            outgoing.remove(model.id)
            incoming.remove(model.id)
            if (!model.canRetry) sendRequests.remove(model.id)
            if (requeue) transfers.remove(model.id)
            entry = HistoryEntry(
                model.id, model.direction, model.peerName, model.peerPlatform, status,
                model.files.map { HistoryFile(it.name, it.size, it.uri) }, model.totalBytes, model.updatedAt, model.error ?: rejectReason,
                peerId = model.peerId,
                kind = model.kind,
                // Links are kept so they can be sent again; text content never goes to history.
                link = if (model.kind == "link") model.text?.take(2048) else null,
                deleteAt = model.deleteAt,
            )
        }
        if (!requeue) history.add(entry)
        // Verified while CrossDrop is in the background: a light "done" tick, unless the
        // result notification is about to buzz anyway.
        if (status == "completed" && !appVisible && !requeue && !notifier.canPost()) feedback.doneInBackground()
        if (model.direction == "incoming") {
            val n = model.files.size
            val text = model.text
            val saved = model.files.mapNotNull { it.uri }
            if (status == "completed" && model.kind == "files" && saved.isNotEmpty()) {
                model.deleteAt?.let { expiring.add(model.id, saved, it) }
                pocket.add(model.files.mapIndexedNotNull { i, f ->
                    f.uri?.let { uri ->
                        PocketItem("${model.id}:$i", uri, f.name.substringAfterLast('/'), f.size, f.mime, now, model.peerName, model.peerPlatform, model.deleteAt)
                    }
                })
            }
            val expiryNote = model.deleteAt?.let { " · Deleted ${inTime(it - now)}, as the sender asked" } ?: ""
            when {
                status == "completed" && model.kind == "link" && text != null && isWebLink(text) -> notifier.result(
                    model.id, "Link from ${model.peerName}", text.take(200),
                    listOf(
                        notifier.activityAction("Open", model.id, linkIntent(text)),
                        notifier.action("Copy", NotificationActionReceiver.COPY, model.id),
                    ),
                    tap = notifier.activityIntent(model.id, linkIntent(text)),
                )
                // Text from a paired Mac: the two-minute "Paste from" pill.
                status == "completed" && model.kind == "text" && text != null && model.peerPlatform == Platform.MACOS.wire -> offerClip(model, text)
                status == "completed" && model.kind != "files" -> notifier.result(
                    model.id, "Text from ${model.peerName}", "Tap Copy to put it on the clipboard.",
                    listOf(notifier.action("Copy", NotificationActionReceiver.COPY, model.id)),
                )
                status == "completed" && model.captureRequestId != null -> notifier.result(
                    model.id, "Received from ${model.peerName}", "Saved to $destinationLabel$expiryNote",
                )
                status == "completed" -> {
                    val single = model.files.singleOrNull()?.uri
                    notifier.result(
                        model.id, "Received ${if (n == 1) "1 file" else "$n files"} from ${model.peerName}", "Saved to $destinationLabel$expiryNote",
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
        } else if (!requeue && (status == "completed" || status == "failed")) {
            val what = if (model.captureRequestId != null) "Photo sent to" else "Sent to"
            notifier.result(model.id, if (status == "completed") "$what ${model.peerName}" else "Couldn’t send to ${model.peerName}", if (status == "completed") "All files verified on the other device." else "Open CrossDrop for details.")
        }
        model.queueId?.let { onQueuedTransferFinished(it, model.peerId, status, model.error, model.targetHost) }
        if (model.direction == "outgoing") model.captureRequestId?.let { onCaptureAnswerFinished(it, status) }
        changed()
        CrossDropService.update(app)
    }

    /** "in 30 min", "in 2 h", "in 3 days". */
    private fun inTime(ms: Long): String {
        val minutes = (ms / 60_000).coerceAtLeast(1)
        return when {
            minutes < 90 -> "in $minutes min"
            minutes < 48 * 60 -> "in ${(minutes + 30) / 60} h"
            else -> "in ${(minutes + 12 * 60) / (24 * 60)} days"
        }
    }

    /** Where received files go, for messages: one folder, or sorted by type. */
    val destinationLabel: String get() = if (prefs.sortByType) MediaStoreStorage.SORTED_LABEL else MediaStoreStorage.LABEL

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
            roomStartedReceiving -> Triple("In a Drip Room", "Room members can send to this phone until the room ends", null)
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
            discoveryWanted && discovery.isActive, discoveryError, network.localNetwork || hotspot.isOn,
            nearby.values.toList(), transfers.values.toList(), pairing.values.toList(), offers.values.toList(), shared,
            mode = if (!receivingEnabled) "off" else if (everyoneOpen) "everyone" else "mine",
            sharedText = sharedText,
            newestDeviceAt = newestDeviceAt,
            screenshotPermission = screenshots.hasPermission(),
            captures = captures.values.filter { it.expiresAt > System.currentTimeMillis() },
            captureFocus = captureFocus,
            clip = clip?.takeIf { it.expiresAt > System.currentTimeMillis() },
            pendingTarget = pendingTarget,
            pendingTargetAt = pendingTargetAt,
            roomHosting = roomHosting,
            roomInvite = roomInvite,
            queueWindowOpen = queueWindowUntil > System.currentTimeMillis(),
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
        /** How long a new network (or app start) looks for devices with queued sends. */
        const val QUEUE_WINDOW_MS = 60_000L
        private const val QUEUE_START_DELAY_MS = 2_000L
        private const val NETWORK_SETTLE_MS = 3_000L
        private val NETWORK_TOKEN = Any()
        private val WIDGET_TOKEN = Any()
        /** A device seen again within this time doesn't retry a queued item that just failed to connect. */
        private const val QUEUE_RETRY_BACKOFF_MS = 30_000L
        /** Failures after which a queued item simply waits for the device again. */
        private val RETRYABLE = setOf(ErrorCode.UNREACHABLE.wire, ErrorCode.CONNECTION_LOST.wire, ErrorCode.TIMEOUT.wire, ErrorCode.BUSY.wire, ErrorCode.NOT_RECEIVING.wire)
        private const val MAX_CAPTURES = 4
        /** After the camera closes unanswered: time for CrossDrop to come back to the front first. */
        private const val CAPTURE_RENOTIFY_DELAY_MS = 1_000L
        const val CLIP_TTL_MS = 2 * 60_000L
        /** Room lengths the UI offers (minutes). */
        val ROOM_MINUTES = setOf(30, 60, 120, 240)

        fun captureNotificationId(requestId: String) = "capture:$requestId"

        /** A private cache file for a photo taken for [requestId]; shared with the camera app via FileProvider. */
        fun captureFile(context: Context, requestId: String): File {
            val dir = File(context.cacheDir, "capture/$requestId").apply { mkdirs() }
            return File(dir, CaptureActivity.photoName())
        }

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
    val captures: List<Engine.PendingCapture> = emptyList(),
    val captureFocus: String? = null,
    val clip: Engine.Clip? = null,
    val pendingTarget: String? = null,
    val pendingTargetAt: Long = 0,
    val roomHosting: String? = null,
    val roomInvite: String? = null,
    val queueWindowOpen: Boolean = false,
)

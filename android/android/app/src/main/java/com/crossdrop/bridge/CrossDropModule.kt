package com.crossdrop.bridge

import android.Manifest
import android.app.Activity
import android.app.DownloadManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import com.crossdrop.capture.CaptureActivity
import com.crossdrop.core.Json
import com.crossdrop.core.Protocol
import com.crossdrop.engine.Engine
import com.crossdrop.engine.NotificationPermissions
import com.crossdrop.pairing.ScanActivity
import com.crossdrop.queue.QueueFullException
import com.crossdrop.screenshots.ScreenshotWatcher
import com.crossdrop.share.SharedFile
import com.crossdrop.share.SharedFiles
import com.crossdrop.specs.NativeCrossDropSpec
import com.facebook.react.bridge.ActivityEventListener
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.modules.core.PermissionAwareActivity
import java.util.concurrent.Executors

/**
 * TurboModule behind specs/NativeCrossDrop.ts. Thin: validates input,
 * forwards to the [Engine] and pushes snapshots to JS as `CrossDropState` events.
 */
class CrossDropModule(private val context: ReactApplicationContext) : NativeCrossDropSpec(context), ActivityEventListener {
    private val engine = Engine.get(context)
    private val io = Executors.newSingleThreadExecutor { r -> Thread(r, "crossdrop-bridge").apply { isDaemon = true } }
    private var pickPromise: Promise? = null
    private var folderPromise: Promise? = null
    private var scanPromise: Promise? = null

    init {
        context.addActivityEventListener(this)
        engine.snapshotListener = { json ->
            if (context.hasActiveReactInstance()) {
                context.emitDeviceEvent(EVENT, Arguments.createMap().apply { putString("json", json) })
            }
        }
    }

    override fun invalidate() {
        context.removeActivityEventListener(this)
        engine.snapshotListener = null
        super.invalidate()
    }

    override fun getSnapshot(promise: Promise) {
        io.execute { promise.resolve(engine.snapshotJson()) }
    }

    override fun startDiscovery() = engine.startDiscovery()

    override fun stopDiscovery() = engine.stopDiscovery()

    override fun setReceiving(enabled: Boolean) = engine.setReceiving(enabled)

    override fun setReceiveMode(mode: String) {
        if (mode in setOf("off", "mine", "everyone")) engine.setReceiveMode(mode)
    }

    override fun pickFolder(promise: Promise) {
        val activity = context.currentActivity ?: return promise.reject("no_activity", "CrossDrop is not in the foreground")
        folderPromise?.resolve("[]")
        folderPromise = promise
        try {
            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), FOLDER_REQUEST)
        } catch (e: ActivityNotFoundException) {
            folderPromise = null
            promise.reject("no_picker", "No folder picker is available")
        }
    }

    override fun scanPairingCode(promise: Promise) {
        val activity = context.currentActivity ?: return promise.reject("no_activity", "CrossDrop is not in the foreground")
        scanPromise?.resolve("")
        scanPromise = promise
        activity.startActivityForResult(Intent(activity, ScanActivity::class.java), SCAN_REQUEST)
    }

    override fun pairWithCode(code: String, mine: Boolean, promise: Promise) {
        io.execute {
            try {
                promise.resolve(engine.pairWithCode(code, mine))
            } catch (e: IllegalArgumentException) {
                promise.reject(codeError(e), "That isn't a valid CrossDrop code")
            } catch (e: com.crossdrop.core.ProtocolException) {
                promise.reject(e.code.wire, e.code.wire)
            } catch (e: Exception) {
                promise.reject("internal", e.javaClass.simpleName)
            }
        }
    }

    override fun sendSharedText(deviceId: String, promise: Promise) {
        io.execute {
            try {
                promise.resolve(engine.sendSharedText(deviceId))
            } catch (e: IllegalStateException) {
                promise.reject("unreachable", "That device is no longer nearby")
            } catch (e: Exception) {
                promise.reject("internal", e.javaClass.simpleName)
            }
        }
    }

    override fun takeClipboard(promise: Promise) {
        // Must run on the main thread while CrossDrop has focus, or Android hides the clipboard.
        context.runOnUiQueueThread { promise.resolve(engine.takeClipboard()) }
    }

    override fun resendHistory(historyId: String, deviceId: String, promise: Promise) {
        io.execute {
            try {
                promise.resolve(engine.resend(historyId, deviceId.ifBlank { null }))
            } catch (e: java.io.FileNotFoundException) {
                promise.reject("file_unreadable", "Those files can no longer be read")
            } catch (e: IllegalStateException) {
                promise.reject("unreachable", "That device is no longer nearby")
            } catch (e: Exception) {
                promise.reject("internal", e.javaClass.simpleName)
            }
        }
    }

    override fun openLink(url: String) {
        engine.openLink(url)
    }

    override fun copyText(text: String) = engine.copyText(text)

    override fun setHotspot(enabled: Boolean, promise: Promise) {
        if (!enabled) {
            engine.hotspot.stop()
            return promise.resolve(false)
        }
        if (Build.VERSION.SDK_INT < 33) return promise.resolve(false)
        val permission = Manifest.permission.NEARBY_WIFI_DEVICES
        if (context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            engine.hotspot.start()
            return promise.resolve(true)
        }
        val activity = context.currentActivity as? PermissionAwareActivity ?: return promise.resolve(false)
        activity.requestPermissions(arrayOf(permission), HOTSPOT_REQUEST) { requestCode, _, results ->
            if (requestCode != HOTSPOT_REQUEST) return@requestPermissions false
            val granted = results.firstOrNull() == PackageManager.PERMISSION_GRANTED
            if (granted) engine.hotspot.start()
            promise.resolve(granted)
            true
        }
    }

    override fun setScreenshotOffer(enabled: Boolean, promise: Promise) {
        if (!enabled) {
            engine.setScreenshotOffer(false)
            return promise.resolve(false)
        }
        val permission = ScreenshotWatcher.permission()
        if (context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            engine.setScreenshotOffer(true)
            return promise.resolve(true)
        }
        val activity = context.currentActivity as? PermissionAwareActivity ?: return promise.resolve(false)
        activity.requestPermissions(arrayOf(permission), PHOTOS_REQUEST) { requestCode, _, results ->
            if (requestCode != PHOTOS_REQUEST) return@requestPermissions false
            val granted = results.firstOrNull() == PackageManager.PERMISSION_GRANTED
            engine.setScreenshotOffer(granted)
            promise.resolve(granted)
            true
        }
    }

    override fun pickFiles(promise: Promise) {
        val activity = context.currentActivity
        if (activity == null) {
            promise.reject("no_activity", "CrossDrop is not in the foreground")
            return
        }
        pickPromise?.resolve("[]")
        pickPromise = promise
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*")
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        try {
            activity.startActivityForResult(intent, PICK_REQUEST)
        } catch (e: ActivityNotFoundException) {
            pickPromise = null
            promise.reject("no_picker", "No file picker is available")
        }
    }

    override fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == SCAN_REQUEST) {
            val promise = scanPromise ?: return
            scanPromise = null
            promise.resolve(if (resultCode == Activity.RESULT_OK) data?.getStringExtra(ScanActivity.EXTRA_CODE) ?: "" else "")
            return
        }
        if (requestCode == FOLDER_REQUEST) {
            val promise = folderPromise ?: return
            folderPromise = null
            val tree = data?.data
            if (resultCode != Activity.RESULT_OK || tree == null) return promise.resolve("[]")
            io.execute {
                runCatching { context.contentResolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
                val files = runCatching { SharedFiles.fromTree(context, tree) }.getOrDefault(emptyList())
                promise.resolve(SharedFiles.listToJson(files))
            }
            return
        }
        if (requestCode != PICK_REQUEST) return
        val promise = pickPromise ?: return
        pickPromise = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            promise.resolve("[]")
            return
        }
        val uris = ArrayList<Uri>()
        data.clipData?.let { clip -> for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let(uris::add) }
        if (uris.isEmpty()) data.data?.let(uris::add)
        io.execute {
            val files = uris.mapNotNull { uri ->
                // Keep read access for retries; released by the system if the source disappears.
                runCatching { context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
                runCatching { SharedFiles.describe(context, uri) }.getOrNull()
            }
            promise.resolve(SharedFiles.listToJson(files))
        }
    }

    override fun onNewIntent(intent: Intent) {}

    override fun sendFiles(deviceId: String, filesJson: String, optionsJson: String, promise: Promise) {
        val files = parseFiles(filesJson, promise) ?: return
        val expiresAfter = parseExpiresAfter(optionsJson, promise) ?: return
        io.execute {
            try {
                promise.resolve(engine.send(deviceId, files, expiresAfter.value))
            } catch (e: IllegalStateException) {
                promise.reject("unreachable", "That device is no longer nearby")
            } catch (e: Exception) {
                promise.reject("internal", e.javaClass.simpleName)
            }
        }
    }

    override fun queueFiles(deviceId: String, filesJson: String, optionsJson: String, promise: Promise) {
        val files = parseFiles(filesJson, promise) ?: return
        val expiresAfter = parseExpiresAfter(optionsJson, promise) ?: return
        io.execute {
            try {
                promise.resolve(engine.queueFiles(deviceId, files, expiresAfter.value))
            } catch (e: QueueFullException) {
                promise.reject("queue_full", "The send-when-nearby queue is full")
            } catch (e: IllegalStateException) {
                promise.reject("not_paired", "Only paired devices can be sent to later")
            } catch (e: java.io.IOException) {
                promise.reject("file_unreadable", "A file could not be read")
            } catch (e: SecurityException) {
                promise.reject("file_unreadable", "A file could not be read")
            } catch (e: Exception) {
                promise.reject("internal", e.javaClass.simpleName)
            }
        }
    }

    override fun queueSharedText(deviceId: String, promise: Promise) {
        io.execute {
            try {
                promise.resolve(engine.queueSharedText(deviceId))
            } catch (e: QueueFullException) {
                promise.reject("queue_full", "The send-when-nearby queue is full")
            } catch (e: IllegalStateException) {
                promise.reject("not_paired", e.message ?: "not_paired")
            } catch (e: Exception) {
                promise.reject("internal", e.javaClass.simpleName)
            }
        }
    }

    override fun cancelQueued(queueId: String) {
        io.execute { engine.cancelQueued(queueId) }
    }

    override fun retryQueued(queueId: String) {
        io.execute { engine.retryQueued(queueId) }
    }

    override fun startCapture(requestId: String, mode: String, promise: Promise) {
        if (mode != CaptureActivity.MODE_PHOTO && mode != CaptureActivity.MODE_PICK) return promise.reject("bad_request", "Unknown mode")
        if (!engine.hasCaptureRequest(requestId)) return promise.reject("expired", "That request has expired")
        val activity = context.currentActivity ?: return promise.reject("no_activity", "CrossDrop is not in the foreground")
        try {
            activity.startActivity(CaptureActivity.intent(activity, requestId, mode))
            engine.clearCaptureFocus()
            promise.resolve(true)
        } catch (e: ActivityNotFoundException) {
            promise.resolve(false)
        }
    }

    override fun declineCapture(requestId: String) = engine.declineCapture(requestId)

    override fun clearCaptureFocus() = engine.clearCaptureFocus()

    override fun openPocketItem(id: String) {
        val item = engine.pocketItem(id) ?: return
        openFile(item.uri)
    }

    override fun sharePocketItem(id: String, promise: Promise) {
        val item = engine.pocketItem(id) ?: return promise.resolve(false)
        try {
            context.startActivity(engine.shareIntent(item))
            promise.resolve(true)
        } catch (e: ActivityNotFoundException) {
            promise.resolve(false)
        } catch (e: SecurityException) {
            promise.resolve(false)
        }
    }

    override fun removePocketItem(id: String, deleteFile: Boolean, promise: Promise) {
        io.execute { promise.resolve(engine.removePocketItem(id, deleteFile)) }
    }

    override fun copyClip(promise: Promise) {
        promise.resolve(engine.copyClip())
    }

    override fun dismissClip() {
        context.runOnUiQueueThread { engine.dismissClip() }
    }

    override fun startRoom(name: String, minutes: Double, promise: Promise) {
        io.execute {
            try {
                promise.resolve(engine.startRoom(name, minutes.toInt()))
            } catch (e: IllegalArgumentException) {
                promise.reject("bad_request", e.message ?: "bad_request")
            } catch (e: IllegalStateException) {
                val code = e.message?.takeIf { it == "not_receiving" || it == "no_network" } ?: "internal"
                promise.reject(code, code)
            } catch (e: Exception) {
                promise.reject("internal", e.javaClass.simpleName)
            }
        }
    }

    override fun joinRoom(code: String, promise: Promise) {
        io.execute {
            try {
                val (name, host) = engine.joinRoom(code)
                promise.resolve(Json.write(linkedMapOf("name" to name, "hostName" to host)))
            } catch (e: IllegalArgumentException) {
                promise.reject(codeError(e), "That isn't a valid Drip Room code")
            } catch (e: com.crossdrop.core.ProtocolException) {
                promise.reject(e.code.wire, e.code.wire)
            } catch (e: Exception) {
                promise.reject("internal", e.javaClass.simpleName)
            }
        }
    }

    override fun leaveRoom() {
        io.execute { engine.leaveRoom() }
    }

    override fun roomQrPng(sizePx: Double, promise: Promise) {
        io.execute {
            try {
                val png = engine.roomQrPng(sizePx.toInt()) ?: return@execute promise.reject("no_room", "Not hosting a room")
                promise.resolve(png)
            } catch (e: Exception) {
                promise.reject("internal", e.javaClass.simpleName)
            }
        }
    }

    override fun clearPendingTarget() = engine.clearPendingTarget()

    /** 'bad_code' | 'own_code' | 'expired' for a code that can't be used. */
    private fun codeError(e: IllegalArgumentException): String =
        e.message?.takeIf { it == "bad_code" || it == "own_code" || it == "expired" } ?: "bad_code"

    private fun parseFiles(filesJson: String, promise: Promise): List<SharedFile>? {
        val files: List<SharedFile> = try {
            SharedFiles.listFromJson(filesJson)
        } catch (e: Exception) {
            promise.reject("bad_request", "Invalid file list")
            return null
        }
        if (files.isEmpty()) {
            promise.reject("bad_request", "No files")
            return null
        }
        return files
    }

    /** Wraps the optional value so "absent" and "invalid" (null) can be told apart. */
    private class Opt(val value: Long?)

    /** SendOptions JSON: {"expiresAfter"?: seconds (60…2 592 000)}. Unknown keys are ignored. */
    private fun parseExpiresAfter(optionsJson: String, promise: Promise): Opt? {
        val options = try {
            if (optionsJson.isBlank()) emptyMap<String, Any?>() else Json.parse(optionsJson) as? Map<*, *>
        } catch (e: Exception) {
            null
        }
        if (options == null) {
            promise.reject("bad_request", "Invalid options")
            return null
        }
        val raw = options["expiresAfter"] ?: return Opt(null)
        val seconds = (raw as? Number)?.toDouble()
        if (seconds == null || seconds % 1.0 != 0.0 || seconds < Protocol.MIN_EXPIRES_AFTER || seconds > Protocol.MAX_EXPIRES_AFTER) {
            promise.reject("bad_request", "expiresAfter must be 60 s to 30 days")
            return null
        }
        return Opt(seconds.toLong())
    }

    override fun respondToPairing(sessionId: String, accept: Boolean, mine: Boolean) = engine.respondToPairing(sessionId, accept, mine)

    override fun respondToOffer(transferId: String, accept: Boolean) = engine.respondToOffer(transferId, accept)

    override fun cancelTransfer(transferId: String) = engine.cancel(transferId)

    override fun dismissTransfer(transferId: String) = engine.dismiss(transferId)

    override fun retryTransfer(transferId: String, promise: Promise) {
        io.execute {
            try {
                promise.resolve(engine.retry(transferId))
            } catch (e: IllegalStateException) {
                promise.reject("unreachable", "That device is no longer nearby")
            } catch (e: Exception) {
                promise.reject("internal", e.javaClass.simpleName)
            }
        }
    }

    override fun forgetDevice(deviceId: String) = engine.forget(deviceId)

    override fun setAutoAccept(deviceId: String, enabled: Boolean) = engine.setAutoAccept(deviceId, enabled)

    override fun setDeviceName(name: String) {
        if (name.isNotBlank()) engine.setDeviceName(name)
    }

    override fun clearSharedFiles() = engine.clearShared()

    override fun clearHistory() = engine.clearHistory()

    override fun setPreference(key: String, value: Boolean) = engine.setPreference(key, value)

    override fun feedback(kind: String) = engine.feedback.perform(kind, context.currentActivity)

    override fun openWifiSettings() {
        val panel = Intent(Settings.Panel.ACTION_WIFI).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(panel)
        } catch (e: ActivityNotFoundException) {
            try {
                context.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            } catch (e: ActivityNotFoundException) {
            }
        }
    }

    override fun openFile(uri: String) {
        try {
            context.startActivity(engine.openFileIntent(uri))
        } catch (e: ActivityNotFoundException) {
            openDownloads()
        } catch (e: SecurityException) {
            openDownloads()
        }
    }

    override fun openDownloads() {
        try {
            context.startActivity(Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: ActivityNotFoundException) {
            // No downloads UI on this device.
        }
    }

    override fun requestNotificationPermission(promise: Promise) {
        val current = NotificationPermissions.status(context, engine.prefs)
        if (Build.VERSION.SDK_INT < 33 || current == "granted") {
            promise.resolve(current)
            return
        }
        val activity = context.currentActivity as? PermissionAwareActivity
        if (activity == null || engine.prefs.notificationPermissionAsked && !shouldShowRationale(activity)) {
            // Android will not show the dialog again; the UI offers system settings instead.
            promise.resolve(current)
            return
        }
        engine.prefs.notificationPermissionAsked = true
        activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST) { requestCode, _, results ->
            if (requestCode != PERMISSION_REQUEST) return@requestPermissions false
            promise.resolve(if (results.firstOrNull() == PackageManager.PERMISSION_GRANTED) "granted" else "denied")
            engine.changed()
            true
        }
    }

    private fun shouldShowRationale(activity: PermissionAwareActivity) =
        activity.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)

    override fun openAppSettings() {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(intent)
        } catch (e: ActivityNotFoundException) {
        }
    }

    companion object {
        const val NAME = NativeCrossDropSpec.NAME
        const val EVENT = "CrossDropState"
        private const val PICK_REQUEST = 4207
        private const val PERMISSION_REQUEST = 4208
        private const val FOLDER_REQUEST = 4209
        private const val SCAN_REQUEST = 4210
        private const val PHOTOS_REQUEST = 4211
        private const val HOTSPOT_REQUEST = 4212
    }
}

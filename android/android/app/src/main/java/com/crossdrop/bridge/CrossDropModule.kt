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
import com.crossdrop.engine.Engine
import com.crossdrop.engine.NotificationPermissions
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

    override fun sendFiles(deviceId: String, filesJson: String, promise: Promise) {
        val files: List<SharedFile> = try {
            SharedFiles.listFromJson(filesJson)
        } catch (e: Exception) {
            promise.reject("bad_request", "Invalid file list")
            return
        }
        if (files.isEmpty()) {
            promise.reject("bad_request", "No files")
            return
        }
        io.execute {
            try {
                promise.resolve(engine.send(deviceId, files))
            } catch (e: IllegalStateException) {
                promise.reject("unreachable", "That device is no longer nearby")
            } catch (e: Exception) {
                promise.reject("internal", e.javaClass.simpleName)
            }
        }
    }

    override fun respondToPairing(sessionId: String, accept: Boolean) = engine.respondToPairing(sessionId, accept)

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
    }
}

package com.crossdrop.screenshots

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.core.content.ContextCompat

/**
 * Notices new screenshots so CrossDrop can offer "Send to <device>". Opt-in,
 * needs photo access, and only runs while CrossDrop's process is alive (for
 * example while "My devices only" keeps it reachable). It reads nothing but
 * the newest screenshot's id and name, and sends nothing on its own: the user
 * taps the notification button to send.
 */
class ScreenshotWatcher(private val context: Context, private val onScreenshot: (uri: Uri, name: String) -> Unit) {
    private val main = Handler(Looper.getMainLooper())
    private var observer: ContentObserver? = null
    private var lastId = -1L

    fun hasPermission(): Boolean = ContextCompat.checkSelfPermission(context, permission()) == PackageManager.PERMISSION_GRANTED

    fun start() {
        if (observer != null || !hasPermission()) return
        val o = object : ContentObserver(main) {
            override fun onChange(selfChange: Boolean, uri: Uri?) = check()
        }
        observer = o
        runCatching { context.contentResolver.registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, o) }
            .onFailure { observer = null }
    }

    fun stop() {
        observer?.let { runCatching { context.contentResolver.unregisterContentObserver(it) } }
        observer = null
    }

    private fun check() {
        val since = System.currentTimeMillis() / 1000 - 15
        val projection = arrayOf(MediaStore.Images.Media._ID, MediaStore.Images.Media.DISPLAY_NAME, MediaStore.Images.Media.RELATIVE_PATH)
        val selection = "${MediaStore.Images.Media.DATE_ADDED} >= ? AND ${MediaStore.Images.Media.IS_PENDING} = 0"
        runCatching {
            context.contentResolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, projection, selection, arrayOf(since.toString()),
                "${MediaStore.Images.Media.DATE_ADDED} DESC",
            )?.use { c ->
                if (!c.moveToFirst()) return
                val id = c.getLong(0)
                val name = c.getString(1) ?: return
                val path = c.getString(2) ?: ""
                if (id == lastId || !path.contains("Screenshot", ignoreCase = true)) return
                lastId = id
                onScreenshot(ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id), name)
            }
        }
    }

    companion object {
        fun permission(): String =
            if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES else Manifest.permission.READ_EXTERNAL_STORAGE
    }
}

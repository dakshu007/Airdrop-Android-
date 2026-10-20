package com.crossdrop.storage

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.os.StatFs
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import com.crossdrop.core.PartialFile
import com.crossdrop.core.ReceiveStorage
import com.crossdrop.core.SavedFile
import java.io.IOException
import java.io.OutputStream

/**
 * Saves received files to Download/CrossDrop through MediaStore (scoped storage,
 * no storage permission needed). Files are inserted as pending, so they stay
 * invisible to other apps until verified; MediaStore picks a non-colliding
 * name ("name (1).ext") instead of overwriting.
 */
class MediaStoreStorage(private val context: Context) : ReceiveStorage {
    private val resolver = context.contentResolver

    override fun availableBytes(): Long = try {
        StatFs(Environment.getExternalStorageDirectory().path).availableBytes
    } catch (e: IllegalArgumentException) {
        Long.MAX_VALUE
    }

    override fun begin(name: String, mime: String?, size: Long): PartialFile {
        // The MIME type comes from the extension, not the sender: a mismatching type makes
        // MediaStore append an extra extension, and the sender's value is only a hint.
        val ext = name.substringAfterLast('.', "").lowercase()
        val type = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, type)
            put(MediaStore.Downloads.RELATIVE_PATH, RELATIVE_PATH)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IOException("MediaStore insert failed")
        val out = try {
            resolver.openOutputStream(uri, "w") ?: throw IOException("no output stream")
        } catch (e: Exception) {
            runCatching { resolver.delete(uri, null, null) }
            throw IOException("cannot open destination", e)
        }
        return Pending(uri, out.buffered(256 * 1024))
    }

    private inner class Pending(private val uri: Uri, override val output: OutputStream) : PartialFile {
        override fun commit(): SavedFile {
            val values = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
            if (resolver.update(uri, values, null, null) != 1) throw IOException("publish failed")
            val finalName = resolver.query(uri, arrayOf(MediaStore.Downloads.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            }
            return SavedFile(finalName ?: "file", uri.toString())
        }

        override fun abort() {
            runCatching { output.close() }
            runCatching { resolver.delete(uri, null, null) }
        }
    }

    companion object {
        val RELATIVE_PATH = "${Environment.DIRECTORY_DOWNLOADS}/CrossDrop"
        const val LABEL = "Download/CrossDrop"
    }
}

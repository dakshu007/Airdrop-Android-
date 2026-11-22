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
import java.io.InputStream
import java.io.OutputStream

/**
 * Saves received files to Download/CrossDrop through MediaStore (scoped storage,
 * no storage permission needed). Files are inserted as pending, so they stay
 * invisible to other apps until verified; MediaStore picks a non-colliding
 * name ("name (1).ext") instead of overwriting.
 *
 * With "Sort by type" on, loose images go to Pictures/CrossDrop, videos to
 * Movies/CrossDrop and audio to Music/CrossDrop; everything else, and every file
 * of a folder transfer (so the folder stays together), goes to Download/CrossDrop.
 *
 * Folders (protocol §9.1) become sub-folders of Download/CrossDrop. A transfer
 * that drops mid-file keeps its pending item for a day so the same file from the
 * same device can continue where it stopped (§9.3); the index of kept items
 * lives in private preferences and holds only content URIs.
 */
class MediaStoreStorage(
    private val context: Context,
    /** Smart arrival: sort loose files into Pictures / Movies / Music by type (read per file). */
    private val sortByType: () -> Boolean = { false },
) : ReceiveStorage {
    private val resolver = context.contentResolver
    private val kept = context.getSharedPreferences("crossdrop_resume", Context.MODE_PRIVATE)

    init {
        // Drop kept parts older than the resume window.
        val now = System.currentTimeMillis()
        for ((key, value) in kept.all) {
            val entry = (value as? String)?.let(::parseEntry)
            if (entry == null || now - entry.second > com.crossdrop.core.Protocol.RESUME_KEEP_MS) {
                entry?.let { runCatching { resolver.delete(it.first, null, null) } }
                kept.edit().remove(key).apply()
            }
        }
    }

    private fun parseEntry(raw: String): Pair<Uri, Long>? {
        val at = raw.substringBefore(' ').toLongOrNull() ?: return null
        val uri = raw.substringAfter(' ', "").takeIf { it.startsWith("content://") } ?: return null
        return Uri.parse(uri) to at
    }

    @Synchronized
    override fun resumableBytes(resumeKey: String): Long {
        val entry = kept.getString(resumeKey, null)?.let(::parseEntry) ?: return 0
        if (System.currentTimeMillis() - entry.second > com.crossdrop.core.Protocol.RESUME_KEEP_MS) return 0
        return try {
            resolver.openFileDescriptor(entry.first, "r")?.use { it.statSize.coerceAtLeast(0) } ?: 0
        } catch (e: Exception) {
            kept.edit().remove(resumeKey).apply()
            0
        }
    }

    override fun availableBytes(): Long = try {
        StatFs(Environment.getExternalStorageDirectory().path).availableBytes
    } catch (e: IllegalArgumentException) {
        Long.MAX_VALUE
    }

    override fun begin(name: String, mime: String?, size: Long): PartialFile =
        begin(name, mime, size, emptyList(), null, 0)

    override fun begin(name: String, mime: String?, size: Long, path: List<String>, resumeKey: String?, resumeFrom: Long): PartialFile {
        if (resumeFrom > 0) {
            val entry = synchronized(this) {
                val e = resumeKey?.let { kept.getString(it, null) }?.let(::parseEntry)
                if (e != null) kept.edit().remove(resumeKey).apply() // claimed by this transfer
                e
            } ?: throw IOException("nothing kept to resume")
            val have = resolver.openFileDescriptor(entry.first, "r")?.use { it.statSize } ?: -1
            if (have != resumeFrom) throw IOException("kept part changed")
            val out = resolver.openOutputStream(entry.first, "wa") ?: throw IOException("no output stream")
            return Pending(entry.first, out.buffered(256 * 1024), resumeKey, resumeFrom, path)
        }
        // The MIME type comes from the extension, not the sender: a mismatching type makes
        // MediaStore append an extra extension, and the sender's value is only a hint.
        val ext = name.substringAfterLast('.', "").lowercase()
        val type = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
        val target = if (path.isEmpty() && sortByType()) targetFor(type) else null
        val uri = target?.let { (collection, root) -> runCatching { insert(collection, root, name, type, path) }.getOrNull() }
            ?: insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, RELATIVE_PATH, name, type, path)
            ?: throw IOException("MediaStore insert failed")
        val out = try {
            resolver.openOutputStream(uri, "w") ?: throw IOException("no output stream")
        } catch (e: Exception) {
            runCatching { resolver.delete(uri, null, null) }
            throw IOException("cannot open destination", e)
        }
        return Pending(uri, out.buffered(256 * 1024), resumeKey, 0, path)
    }

    private fun insert(collection: Uri, root: String, name: String, type: String, path: List<String>): Uri? {
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, type)
            put(MediaStore.MediaColumns.RELATIVE_PATH, (listOf(root) + path).joinToString("/"))
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        return resolver.insert(collection, values)
    }

    /** Collection and folder for a sorted file, or null for Download/CrossDrop. */
    private fun targetFor(type: String): Pair<Uri, String>? = when {
        type.startsWith("image/") -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI to "${Environment.DIRECTORY_PICTURES}/CrossDrop"
        type.startsWith("video/") -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI to "${Environment.DIRECTORY_MOVIES}/CrossDrop"
        type.startsWith("audio/") -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI to "${Environment.DIRECTORY_MUSIC}/CrossDrop"
        else -> null
    }

    private inner class Pending(
        private val uri: Uri,
        override val output: OutputStream,
        private val resumeKey: String?,
        override val existingBytes: Long,
        private val path: List<String>,
    ) : PartialFile {
        override fun openExisting(): InputStream? = if (existingBytes > 0) resolver.openInputStream(uri) else null

        override fun keepForResume() {
            val key = resumeKey
            if (key == null) {
                abort()
                return
            }
            runCatching { output.close() }
            synchronized(this@MediaStoreStorage) {
                kept.edit().putString(key, "${System.currentTimeMillis()} $uri").apply()
            }
        }

        override fun commit(): SavedFile {
            val values = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            if (resolver.update(uri, values, null, null) != 1) throw IOException("publish failed")
            val finalName = resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            }
            return SavedFile((path + (finalName ?: "file")).joinToString("/"), uri.toString())
        }

        override fun abort() {
            runCatching { output.close() }
            runCatching { resolver.delete(uri, null, null) }
        }
    }

    companion object {
        val RELATIVE_PATH = "${Environment.DIRECTORY_DOWNLOADS}/CrossDrop"
        const val LABEL = "Download/CrossDrop"
        const val SORTED_LABEL = "Pictures, Movies, Music or Download › CrossDrop"

        /** Deletes an item CrossDrop saved (expiring drops, Pocket). False when it isn't ours any more or is gone. */
        fun delete(context: Context, uri: String): Boolean = try {
            context.contentResolver.delete(Uri.parse(uri), null, null) > 0
        } catch (e: SecurityException) {
            false
        } catch (e: IllegalArgumentException) {
            false
        }
    }
}

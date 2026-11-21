package com.crossdrop.share

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import com.crossdrop.core.Json
import java.io.File

/** A file chosen in the share sheet or picker. Bytes are read later, natively, by the engine. */
data class SharedFile(
    val uri: String,
    val name: String,
    val size: Long?,
    val mime: String?,
    /** Folders to recreate on the receiver, outermost first (from a picked folder, §9.1). */
    val path: List<String> = emptyList(),
) {
    fun toJson(): Map<String, Any?> = linkedMapOf("uri" to uri, "name" to name, "size" to size, "mime" to mime, "path" to path.joinToString("/"))
}

/** A link or short text handed over by the share sheet or the clipboard (§9.2). */
data class SharedText(val kind: String, val text: String) {
    fun toJson(): Map<String, Any?> = linkedMapOf("kind" to kind, "preview" to text.take(500), "length" to text.length)

    companion object {
        /** A lone http(s) URL becomes a link; other text up to the protocol limit stays text. */
        fun of(raw: String): SharedText? {
            val text = raw.trim()
            if (text.isEmpty() || text.toByteArray(Charsets.UTF_8).size > com.crossdrop.core.Protocol.MAX_TEXT_PAYLOAD) return null
            val isLink = text.length <= 2048 && !text.any { it.isWhitespace() } &&
                (text.startsWith("https://", ignoreCase = true) || text.startsWith("http://", ignoreCase = true))
            return SharedText(if (isLink) "link" else "text", text)
        }
    }
}

object SharedFiles {
    /** Files from an ACTION_SEND / ACTION_SEND_MULTIPLE intent, or null for other intents. */
    fun fromIntent(context: Context, intent: Intent?): List<SharedFile>? {
        if (intent == null) return null
        val uris: List<Uri> = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(streamExtra(intent))
            Intent.ACTION_SEND_MULTIPLE -> streamListExtra(intent)
            else -> return null
        }
        if (uris.isEmpty()) {
            // Long text that can't travel as a handoff becomes a small .txt file.
            val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() ?: return emptyList()
            return listOf(textFile(context, text, intent.getStringExtra(Intent.EXTRA_SUBJECT)))
        }
        return uris.mapNotNull { runCatching { describe(context, it) }.getOrNull() }
    }

    /** A shared link or short text (sent as a handoff, not a file), or null. */
    fun textFromIntent(intent: Intent?): SharedText? {
        if (intent?.action != Intent.ACTION_SEND || streamExtra(intent) != null) return null
        return intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.let { SharedText.of(it) }
    }

    /**
     * Every file under a picked folder (ACTION_OPEN_DOCUMENT_TREE), each with its
     * folder path starting at the picked folder's name. Stops at [MAX_TREE_FILES].
     */
    fun fromTree(context: Context, tree: Uri): List<SharedFile> {
        val resolver = context.contentResolver
        val rootId = android.provider.DocumentsContract.getTreeDocumentId(tree)
        val out = ArrayList<SharedFile>()
        fun walk(docId: String, path: List<String>, depth: Int) {
            if (depth > com.crossdrop.core.Protocol.MAX_PATH_COMPONENTS || out.size >= MAX_TREE_FILES) return
            val children = android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId)
            val cols = arrayOf(
                android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                android.provider.DocumentsContract.Document.COLUMN_MIME_TYPE,
                android.provider.DocumentsContract.Document.COLUMN_SIZE,
            )
            resolver.query(children, cols, null, null, null)?.use { c ->
                while (c.moveToNext() && out.size < MAX_TREE_FILES) {
                    val id = c.getString(0) ?: continue
                    val name = c.getString(1) ?: continue
                    val mime = c.getString(2)
                    if (mime == android.provider.DocumentsContract.Document.MIME_TYPE_DIR) {
                        walk(id, path + name, depth + 1)
                    } else {
                        val uri = android.provider.DocumentsContract.buildDocumentUriUsingTree(tree, id)
                        out.add(SharedFile(uri.toString(), name, if (c.isNull(3)) null else c.getLong(3), mime, path))
                    }
                }
            }
        }
        val rootName = resolver.query(
            android.provider.DocumentsContract.buildDocumentUriUsingTree(tree, rootId),
            arrayOf(android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null,
        )?.use { if (it.moveToFirst()) it.getString(0) else null } ?: "Folder"
        walk(rootId, listOf(rootName), 1)
        return out
    }

    const val MAX_TREE_FILES = 1000

    fun describe(context: Context, uri: Uri): SharedFile {
        var name: String? = null
        var size: Long? = null
        if (uri.scheme == ContentResolver.SCHEME_CONTENT) {
            // Some providers refuse metadata queries even when reading is allowed; fall back below.
            runCatching {
                context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                    if (c.moveToFirst()) {
                        val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        val si = c.getColumnIndex(OpenableColumns.SIZE)
                        if (ni >= 0 && !c.isNull(ni)) name = c.getString(ni)
                        if (si >= 0 && !c.isNull(si)) size = c.getLong(si).takeIf { it >= 0 }
                    }
                }
            }
        } else if (uri.scheme == ContentResolver.SCHEME_FILE) {
            val f = File(uri.path ?: "")
            name = f.name
            size = f.length()
        }
        val mime = runCatching { context.contentResolver.getType(uri) }.getOrNull()
        return SharedFile(uri.toString(), name?.takeIf { it.isNotBlank() } ?: fallbackName(uri, mime), size, mime)
    }

    /** "Image 1000000024.png" rather than a bare provider id when the provider won't tell us the name. */
    private fun fallbackName(uri: Uri, mime: String?): String {
        val kind = when {
            mime?.startsWith("image/") == true -> "Image"
            mime?.startsWith("video/") == true -> "Video"
            mime?.startsWith("audio/") == true -> "Audio"
            else -> "File"
        }
        val id = uri.lastPathSegment?.substringAfterLast('/')?.takeIf { it.isNotBlank() }
        val ext = mime?.let { android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(it) }
        return listOfNotNull(kind, id).joinToString(" ") + (ext?.let { ".$it" } ?: "")
    }

    fun listToJson(files: List<SharedFile>): String = Json.write(files.map { it.toJson() })

    @Suppress("UNCHECKED_CAST")
    fun listFromJson(json: String): List<SharedFile> = (Json.parse(json) as List<Map<String, Any?>>).map {
        SharedFile(
            uri = it["uri"] as String,
            name = it["name"] as String,
            size = (it["size"] as? Number)?.toLong(),
            mime = it["mime"] as String?,
            path = (it["path"] as? String)?.split('/')?.filter { p -> p.isNotBlank() } ?: emptyList(),
        )
    }

    private fun textFile(context: Context, text: String, subject: String?): SharedFile {
        val dir = File(context.cacheDir, "shared-text").apply { mkdirs() }
        val base = subject?.replace(Regex("[^\\p{L}\\p{N} _-]"), "")?.trim()?.take(60)?.ifBlank { null } ?: "Shared text"
        val f = File(dir, "$base.txt")
        f.writeText(text)
        return SharedFile(Uri.fromFile(f).toString(), f.name, f.length(), "text/plain")
    }

    @Suppress("DEPRECATION")
    private fun streamExtra(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri

    @Suppress("DEPRECATION")
    private fun streamListExtra(intent: Intent): List<Uri> =
        (if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM))?.filterNotNull() ?: emptyList()
}

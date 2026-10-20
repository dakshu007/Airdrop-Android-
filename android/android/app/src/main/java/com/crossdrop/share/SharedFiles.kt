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
data class SharedFile(val uri: String, val name: String, val size: Long?, val mime: String?) {
    fun toJson(): Map<String, Any?> = linkedMapOf("uri" to uri, "name" to name, "size" to size, "mime" to mime)
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
            // Plain text shares become a small .txt file so they can still be sent.
            val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() ?: return emptyList()
            return listOf(textFile(context, text, intent.getStringExtra(Intent.EXTRA_SUBJECT)))
        }
        return uris.mapNotNull { runCatching { describe(context, it) }.getOrNull() }
    }

    fun describe(context: Context, uri: Uri): SharedFile {
        var name: String? = null
        var size: Long? = null
        if (uri.scheme == ContentResolver.SCHEME_CONTENT) {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val si = c.getColumnIndex(OpenableColumns.SIZE)
                    if (ni >= 0 && !c.isNull(ni)) name = c.getString(ni)
                    if (si >= 0 && !c.isNull(si)) size = c.getLong(si).takeIf { it >= 0 }
                }
            }
        } else if (uri.scheme == ContentResolver.SCHEME_FILE) {
            val f = File(uri.path ?: "")
            name = f.name
            size = f.length()
        }
        val mime = context.contentResolver.getType(uri)
        return SharedFile(uri.toString(), name?.takeIf { it.isNotBlank() } ?: (uri.lastPathSegment ?: "file"), size, mime)
    }

    fun listToJson(files: List<SharedFile>): String = Json.write(files.map { it.toJson() })

    @Suppress("UNCHECKED_CAST")
    fun listFromJson(json: String): List<SharedFile> = (Json.parse(json) as List<Map<String, Any?>>).map {
        SharedFile(
            uri = it["uri"] as String,
            name = it["name"] as String,
            size = (it["size"] as? Number)?.toLong(),
            mime = it["mime"] as String?,
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

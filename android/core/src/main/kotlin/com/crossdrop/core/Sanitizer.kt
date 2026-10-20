package com.crossdrop.core

import java.text.Normalizer

/** Receiver-side file name rules, docs/protocol-v1.md §6.5. */
object Sanitizer {
    private const val MAX_BYTES = 200
    private const val MAX_EXT_BYTES = 16
    private const val FORBIDDEN = "<>:\"|?*"

    fun fileName(input: String): String {
        var s = Normalizer.normalize(input, Normalizer.Form.NFC)
        val cut = maxOf(s.lastIndexOf('/'), s.lastIndexOf('\\'))
        s = s.substring(cut + 1)
        s = buildString {
            for (c in s) {
                val code = c.code
                if (code <= 0x1f || code in 0x7f..0x9f) continue
                append(if (FORBIDDEN.indexOf(c) >= 0) '_' else c)
            }
        }
        s = s.trim().trimStart('.')
        if (s.isEmpty()) return "file"
        if (utf8Len(s) <= MAX_BYTES) return s

        val dot = s.lastIndexOf('.')
        val ext = if (dot > 0 && utf8Len(s.substring(dot)) <= MAX_EXT_BYTES) s.substring(dot) else ""
        val stem = s.substring(0, s.length - ext.length)
        val budget = MAX_BYTES - utf8Len(ext)
        val out = StringBuilder()
        var used = 0
        var i = 0
        while (i < stem.length) {
            val cp = stem.codePointAt(i)
            val n = Character.charCount(cp)
            val bytes = utf8Len(stem.substring(i, i + n))
            if (used + bytes > budget) break
            out.appendCodePoint(cp)
            used += bytes
            i += n
        }
        return out.toString() + ext
    }

    /** "name.ext" -> "name (n).ext" for collision handling. */
    fun numbered(name: String, n: Int): String {
        val dot = name.lastIndexOf('.')
        return if (dot > 0) "${name.substring(0, dot)} ($n)${name.substring(dot)}" else "$name ($n)"
    }

    private fun utf8Len(s: String) = s.toByteArray(Charsets.UTF_8).size
}

package com.crossdrop.core

/**
 * Minimal strict JSON reader/writer for protocol control messages.
 *
 * Self-contained so the JVM tests and the Android app parse identically
 * (Android's bundled org.json is lenient about types). Objects decode to
 * [LinkedHashMap], arrays to [List], integers to [Long], other numbers to
 * [Double]. Duplicate keys and trailing data are rejected.
 */
object Json {
    private const val MAX_DEPTH = 32

    fun parse(text: String): Any? {
        val p = Parser(text)
        p.skipWs()
        val value = p.readValue(0)
        p.skipWs()
        if (!p.atEnd()) throw JsonException("trailing data")
        return value
    }

    fun parseObject(bytes: ByteArray): Map<String, Any?> {
        val text = try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
                .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
                .decode(java.nio.ByteBuffer.wrap(bytes))
                .toString()
        } catch (e: java.nio.charset.CharacterCodingException) {
            throw JsonException("invalid UTF-8")
        }
        @Suppress("UNCHECKED_CAST")
        return parse(text) as? Map<String, Any?> ?: throw JsonException("not an object")
    }

    fun write(value: Any?): String = StringBuilder().also { writeValue(it, value) }.toString()

    fun encode(value: Map<String, Any?>): ByteArray = write(value).toByteArray(Charsets.UTF_8)

    private fun writeValue(sb: StringBuilder, value: Any?) {
        when (value) {
            null -> sb.append("null")
            is String -> writeString(sb, value)
            is Boolean -> sb.append(if (value) "true" else "false")
            is Int, is Long, is Short, is Byte -> sb.append(value.toString())
            is Double -> {
                require(value.isFinite()) { "non-finite number" }
                if (value == Math.floor(value) && Math.abs(value) < 1e15) sb.append(value.toLong()) else sb.append(value)
            }
            is Map<*, *> -> {
                sb.append('{')
                var first = true
                for ((k, v) in value) {
                    if (!first) sb.append(',')
                    first = false
                    writeString(sb, k as String)
                    sb.append(':')
                    writeValue(sb, v)
                }
                sb.append('}')
            }
            is Iterable<*> -> {
                sb.append('[')
                var first = true
                for (v in value) {
                    if (!first) sb.append(',')
                    first = false
                    writeValue(sb, v)
                }
                sb.append(']')
            }
            else -> throw IllegalArgumentException("unsupported JSON value: ${value::class.java.simpleName}")
        }
    }

    private fun writeString(sb: StringBuilder, s: String) {
        sb.append('"')
        for (c in s) {
            when (c) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                '\b' -> sb.append("\\b")
                '\u000C' -> sb.append("\\f")
                else -> if (c < ' ' || c == ' ' || c == ' ') {
                    sb.append("\\u").append(String.format("%04x", c.code))
                } else {
                    sb.append(c)
                }
            }
        }
        sb.append('"')
    }

    private class Parser(private val s: String) {
        private var i = 0

        fun atEnd() = i >= s.length

        fun skipWs() {
            while (i < s.length && (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t')) i++
        }

        fun readValue(depth: Int): Any? {
            if (depth > MAX_DEPTH) throw JsonException("nesting too deep")
            if (atEnd()) throw JsonException("unexpected end")
            return when (val c = s[i]) {
                '{' -> readObject(depth)
                '[' -> readArray(depth)
                '"' -> readString()
                't' -> literal("true", true)
                'f' -> literal("false", false)
                'n' -> literal("null", null)
                else -> if (c == '-' || c in '0'..'9') readNumber() else throw JsonException("unexpected character")
            }
        }

        private fun literal(word: String, value: Any?): Any? {
            if (!s.startsWith(word, i)) throw JsonException("bad literal")
            i += word.length
            return value
        }

        private fun readObject(depth: Int): Map<String, Any?> {
            val map = LinkedHashMap<String, Any?>()
            i++ // {
            skipWs()
            if (peek() == '}') { i++; return map }
            while (true) {
                skipWs()
                if (peek() != '"') throw JsonException("expected key")
                val key = readString()
                skipWs()
                expect(':')
                skipWs()
                if (map.containsKey(key)) throw JsonException("duplicate key")
                map[key] = readValue(depth + 1)
                skipWs()
                when (next()) {
                    ',' -> continue
                    '}' -> return map
                    else -> throw JsonException("expected , or }")
                }
            }
        }

        private fun readArray(depth: Int): List<Any?> {
            val list = ArrayList<Any?>()
            i++ // [
            skipWs()
            if (peek() == ']') { i++; return list }
            while (true) {
                skipWs()
                list.add(readValue(depth + 1))
                skipWs()
                when (next()) {
                    ',' -> continue
                    ']' -> return list
                    else -> throw JsonException("expected , or ]")
                }
            }
        }

        private fun readString(): String {
            expect('"')
            val sb = StringBuilder()
            while (true) {
                if (atEnd()) throw JsonException("unterminated string")
                val c = s[i++]
                when {
                    c == '"' -> return sb.toString()
                    c == '\\' -> {
                        if (atEnd()) throw JsonException("bad escape")
                        when (val e = s[i++]) {
                            '"' -> sb.append('"')
                            '\\' -> sb.append('\\')
                            '/' -> sb.append('/')
                            'b' -> sb.append('\b')
                            'f' -> sb.append('\u000C')
                            'n' -> sb.append('\n')
                            'r' -> sb.append('\r')
                            't' -> sb.append('\t')
                            'u' -> {
                                if (i + 4 > s.length) throw JsonException("bad unicode escape")
                                val code = s.substring(i, i + 4).toIntOrNull(16) ?: throw JsonException("bad unicode escape")
                                i += 4
                                sb.append(code.toChar())
                            }
                            else -> throw JsonException("bad escape '$e'")
                        }
                    }
                    c < ' ' -> throw JsonException("control character in string")
                    else -> sb.append(c)
                }
            }
        }

        private fun readNumber(): Any {
            val start = i
            if (peek() == '-') i++
            if (peek() == '0') {
                i++
            } else if (peek() in '1'..'9') {
                while (!atEnd() && s[i] in '0'..'9') i++
            } else {
                throw JsonException("bad number")
            }
            var isInteger = true
            if (!atEnd() && s[i] == '.') {
                isInteger = false
                i++
                if (atEnd() || s[i] !in '0'..'9') throw JsonException("bad number")
                while (!atEnd() && s[i] in '0'..'9') i++
            }
            if (!atEnd() && (s[i] == 'e' || s[i] == 'E')) {
                isInteger = false
                i++
                if (!atEnd() && (s[i] == '+' || s[i] == '-')) i++
                if (atEnd() || s[i] !in '0'..'9') throw JsonException("bad number")
                while (!atEnd() && s[i] in '0'..'9') i++
            }
            val text = s.substring(start, i)
            if (isInteger) text.toLongOrNull()?.let { return it }
            return text.toDouble()
        }

        private fun peek(): Char = if (atEnd()) '\u0000' else s[i]

        private fun next(): Char = if (atEnd()) throw JsonException("unexpected end") else s[i++]

        private fun expect(c: Char) {
            if (next() != c) throw JsonException("expected '$c'")
        }
    }
}

class JsonException(message: String) : Exception(message)

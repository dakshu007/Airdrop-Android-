package com.crossdrop.core

import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap

/**
 * A Drip Room (§9.9): temporary group trust for a meeting. Everyone holding the room
 * key can pair with everyone else in the room without comparing codes, and the trust
 * this creates ends at [expiresAt] (unix seconds).
 */
class Room(
    /** 16 random bytes, base64url without padding (22 characters). */
    val id: String,
    key: ByteArray,
    val name: String,
    /** Unix seconds. */
    val expiresAt: Long,
) {
    private val secret: ByteArray = key.copyOf()

    init {
        require(Rooms.isValidId(id)) { "bad room id" }
        require(secret.size == 32) { "room key must be 32 bytes" }
        require(name.isNotBlank() && name.codePointCount(0, name.length) <= 64) { "bad room name" }
        require(expiresAt > 0) { "bad expiry" }
    }

    /** The 32-byte room key. */
    val key: ByteArray get() = secret.copyOf()

    val expiresAtMillis: Long get() = expiresAt * 1000

    fun isActive(nowMs: Long = System.currentTimeMillis()): Boolean = nowMs < expiresAtMillis

    /** The DNS-SD TXT `r` value devices in this room advertise (a hint only). */
    val hint: String get() = Rooms.hint(id)

    /** `pair.request` proof: HMAC-SHA256(roomKey, "CrossDrop/1 room|" || TH). */
    fun proof(transcriptHash: ByteArray): ByteArray = Hashing.hmacSha256(secret, Protocol.LABEL_ROOM, transcriptHash)

    /** `pair.confirm` proof from the receiver: HMAC-SHA256(roomKey, "CrossDrop/1 room-confirm|" || TH). */
    fun confirmProof(transcriptHash: ByteArray): ByteArray = Hashing.hmacSha256(secret, Protocol.LABEL_ROOM_CONFIRM, transcriptHash)

    override fun equals(other: Any?) = other is Room && other.id == id && other.secret.contentEquals(secret) &&
        other.name == name && other.expiresAt == expiresAt

    override fun hashCode() = id.hashCode()

    override fun toString() = "Room($name, expires $expiresAt)"
}

/**
 * What a room QR code carries (§9.9):
 * `crossdrop://room?v=1&id=<roomId>&k=<roomKey>&n=<name>&exp=<unix>&h=<hosts>&p=<port>&fp=<fingerprint>`.
 * [hosts], [port] and [fingerprint] describe the device that shows the code, so a joiner
 * can reach it where DNS-SD is blocked.
 */
data class RoomInvite(
    val room: Room,
    val hosts: List<String>,
    val port: Int,
    /** SHA-256 of the showing device's identity key, lowercase hex. */
    val fingerprint: String,
) {
    init {
        require(hosts.isNotEmpty() && hosts.size <= MAX_HOSTS && hosts.all { HOST.matches(it) }) { "bad hosts" }
        require(port in 1..65535) { "bad port" }
        require(HEX64.matches(fingerprint)) { "bad fingerprint" }
    }

    fun toUri(): String {
        val pairs = listOf(
            "v" to Protocol.VERSION.toString(),
            "id" to room.id,
            "k" to Rooms.b64url(room.key),
            "n" to room.name,
            "exp" to room.expiresAt.toString(),
            "h" to hosts.joinToString(","),
            "p" to port.toString(),
            "fp" to fingerprint,
        )
        return PREFIX + pairs.joinToString("&") { (k, v) -> "$k=${percentEncode(v)}" }
    }

    companion object {
        const val PREFIX = "crossdrop://room?"
        private const val MAX_URI = 2048
        private const val MAX_HOSTS = 8
        private val HEX64 = Regex("^[0-9a-f]{64}$")
        private val HOST = Regex("^[0-9A-Za-z.:%_-]{1,64}$")
        private val DIGITS = Regex("^[0-9]{1,12}$")
        private val KEY = Regex("^[A-Za-z0-9_-]{43}$")

        /**
         * Parses a room QR code. Returns null for anything malformed, a room that has
         * expired, or one that claims to last longer than 4 hours (plus clock skew).
         */
        fun parse(raw: String, nowSeconds: Long = System.currentTimeMillis() / 1000): RoomInvite? {
            if (raw.length > MAX_URI || !raw.startsWith(PREFIX)) return null
            val q = HashMap<String, String>()
            for (part in raw.substring(PREFIX.length).split('&')) {
                val eq = part.indexOf('=')
                if (eq <= 0) return null
                val key = part.substring(0, eq)
                val value = percentDecode(part.substring(eq + 1)) ?: return null
                if (q.put(key, value) != null) return null // duplicate key
            }
            if (q["v"] != Protocol.VERSION.toString()) return null
            val id = q["id"]?.takeIf { Rooms.isValidId(it) } ?: return null
            val key = q["k"]?.takeIf { KEY.matches(it) }?.let { Rooms.b64urlDecode(it) }?.takeIf { it.size == 32 } ?: return null
            val exp = q["exp"]?.takeIf { DIGITS.matches(it) }?.toLong() ?: return null
            if (exp <= nowSeconds || exp > nowSeconds + Protocol.ROOM_MAX_TTL_S + Protocol.ROOM_CLOCK_SKEW_S) return null
            val hosts = (q["h"] ?: return null).split(',').map { it.trim() }
            if (hosts.isEmpty() || hosts.size > MAX_HOSTS || !hosts.all { HOST.matches(it) }) return null
            val port = q["p"]?.takeIf { DIGITS.matches(it) }?.toLong()?.takeIf { it in 1..65535 }?.toInt() ?: return null
            val fp = q["fp"]?.takeIf { HEX64.matches(it) } ?: return null
            val name = Rooms.cleanName(q["n"])
            return RoomInvite(Room(id, key, name, exp), hosts, port, fp)
        }

        private fun isUnreserved(b: Int) = b in 'A'.code..'Z'.code || b in 'a'.code..'z'.code || b in '0'.code..'9'.code ||
            b == '-'.code || b == '.'.code || b == '_'.code || b == '~'.code

        /** Percent-encodes everything except RFC 3986 unreserved characters (identical to the Swift core). */
        internal fun percentEncode(s: String): String {
            val sb = StringBuilder()
            for (byte in s.toByteArray(Charsets.UTF_8)) {
                val b = byte.toInt() and 0xff
                if (isUnreserved(b)) sb.append(b.toChar()) else sb.append('%').append("%02X".format(b))
            }
            return sb.toString()
        }

        /** Decodes %XX escapes (and `+` as a space); null for a malformed escape or invalid UTF-8. */
        internal fun percentDecode(s: String): String? {
            val out = ByteArrayOutputStream(s.length)
            var i = 0
            while (i < s.length) {
                val c = s[i]
                when {
                    c == '%' -> {
                        if (i + 2 >= s.length) return null
                        val hi = Character.digit(s[i + 1], 16)
                        val lo = Character.digit(s[i + 2], 16)
                        if (hi < 0 || lo < 0) return null
                        out.write(hi * 16 + lo)
                        i += 3
                    }
                    c == '+' -> { out.write(' '.code); i++ }
                    c.code > 0x7e || c.code < 0x21 -> return null
                    else -> { out.write(c.code); i++ }
                }
            }
            return try {
                Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(out.toByteArray())).toString()
            } catch (e: java.nio.charset.CharacterCodingException) {
                null
            }
        }
    }
}

/**
 * The rooms this device is in (§9.9), shared by its receiver (to check `pair.request`
 * proofs) and its sender (to present them). Thread-safe. Expired rooms are dropped.
 */
class Rooms {
    private val rooms = ConcurrentHashMap<String, Room>()
    private val random = SecureRandom()

    /** Creates a room lasting [ttlSeconds] (at most 4 hours) and joins it. */
    fun create(name: String, ttlSeconds: Long): Room {
        require(ttlSeconds in 1..Protocol.ROOM_MAX_TTL_S) { "room lifetime must be 1 s to 4 h" }
        val id = b64url(ByteArray(16).also(random::nextBytes))
        val key = ByteArray(32).also(random::nextBytes)
        val room = Room(id, key, cleanName(name), System.currentTimeMillis() / 1000 + ttlSeconds)
        check(join(room))
        return room
    }

    /** Joins [room] (from a scanned code). False when it has expired or lasts implausibly long. */
    fun join(room: Room): Boolean {
        val now = System.currentTimeMillis() / 1000
        if (room.expiresAt <= now || room.expiresAt > now + Protocol.ROOM_MAX_TTL_S + Protocol.ROOM_CLOCK_SKEW_S) return false
        rooms[room.id] = room
        return true
    }

    fun leave(id: String) {
        rooms.remove(id)
    }

    fun leaveAll() = rooms.clear()

    /** Active rooms, soonest to expire first. */
    fun active(): List<Room> {
        purgeExpired()
        return rooms.values.sortedBy { it.expiresAt }
    }

    fun get(id: String): Room? = rooms[id]?.takeIf { it.isActive() }

    fun purgeExpired() {
        val now = System.currentTimeMillis()
        rooms.entries.removeIf { !it.value.isActive(now) }
    }

    /** TXT `r` hints for the active rooms (at most [Protocol.MAX_ROOM_HINTS]). */
    fun hints(): List<String> = active().take(Protocol.MAX_ROOM_HINTS).map { it.hint }

    /** The active room a discovered device's hint points at, if any. A hint is never proof. */
    fun forHint(hint: String): Room? = active().firstOrNull { it.hint == hint }

    /** The room whose key produced [proof] over this handshake, compared in constant time. */
    internal fun verify(id: String, proof: ByteArray, transcriptHash: ByteArray): Room? {
        val room = get(id) ?: return null
        return room.takeIf { MessageDigest.isEqual(it.proof(transcriptHash), proof) }
    }

    companion object {
        private val ID = Regex("^[A-Za-z0-9_-]{22}$")
        private val HINT = Regex("^[0-9a-f]{16}$")

        fun isValidId(id: String): Boolean = ID.matches(id) && b64urlDecode(id)?.size == 16

        /** hex(SHA-256("CrossDrop/1 room|" + roomId)[0:8]). */
        fun hint(roomId: String): String =
            Hashing.sha256(Protocol.LABEL_ROOM, roomId.toByteArray(Charsets.US_ASCII)).copyOfRange(0, 8).toHex()

        /** Parses a TXT `r` value: comma-separated hints, invalid ones dropped. */
        fun parseHints(value: String?): List<String> =
            value?.split(',')?.map { it.trim() }?.filter { HINT.matches(it) }?.take(Protocol.MAX_ROOM_HINTS) ?: emptyList()

        internal fun cleanName(raw: String?): String {
            val noControls = (raw ?: "").filter { !(it.code <= 0x1f || it.code in 0x7f..0x9f) }.trim()
            val cps = noControls.codePoints().limit(64).toArray()
            return String(cps, 0, cps.size).trim().ifEmpty { "Room" }
        }

        internal fun b64url(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

        /** Strict base64url (no padding): null unless [s] is the canonical encoding of its bytes. */
        internal fun b64urlDecode(s: String): ByteArray? {
            val bytes = try {
                Base64.getUrlDecoder().decode(s)
            } catch (e: IllegalArgumentException) {
                return null
            }
            return bytes.takeIf { b64url(it) == s }
        }
    }
}

/** DNS-SD TXT helpers (§2, §9.5, §9.9) for platform advertisers. */
object Discovery {
    /** TXT attributes: `v`, `id`, `p`, plus `m=1` in "My devices only" mode and `r` room hints. */
    fun txtAttributes(deviceId: String, platform: Platform, privateMode: Boolean = false, roomHints: List<String> = emptyList()): Map<String, String> {
        val m = linkedMapOf("v" to Protocol.VERSION.toString(), "id" to deviceId, "p" to platform.wire)
        if (privateMode) m["m"] = "1"
        val hints = Rooms.parseHints(roomHints.joinToString(","))
        if (hints.isNotEmpty()) m["r"] = hints.joinToString(",")
        return m
    }
}

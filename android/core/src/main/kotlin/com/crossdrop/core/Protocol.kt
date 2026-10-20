package com.crossdrop.core

import java.util.Base64

/** Constants and validation rules from docs/protocol-v1.md. */
object Protocol {
    const val VERSION = 1
    const val SERVICE_TYPE = "_crossdrop._tcp"

    const val MAX_PLAINTEXT_FRAME = 65536
    const val MAX_CONTROL_BODY = 65536
    const val MAX_DATA_BODY = 262144
    const val MAX_ENCRYPTED_FRAME = 1 + MAX_DATA_BODY + 16
    const val MAX_FILES = 1000
    const val MAX_INBOUND_CONNECTIONS = 3
    const val MAX_SAFE_SIZE = 9007199254740991L // 2^53 - 1

    const val KIND_CONTROL: Byte = 0x01
    const val KIND_DATA: Byte = 0x02

    const val CONNECT_TIMEOUT_MS = 10_000
    const val HANDSHAKE_STEP_TIMEOUT_MS = 15_000
    const val HUMAN_DECISION_TIMEOUT_MS = 120_000L
    const val STREAM_IDLE_TIMEOUT_MS = 30_000L
    const val PROGRESS_INTERVAL_MS = 500L
    /** Free space required on top of the offer total (§6.5). */
    const val STORAGE_MARGIN_BYTES = 64L * 1024 * 1024

    val LABEL_TRANSCRIPT = "CrossDrop/1 transcript".toByteArray(Charsets.US_ASCII)
    val LABEL_CLIENT_PROOF = "CrossDrop/1 client-proof".toByteArray(Charsets.US_ASCII)
    val LABEL_SERVER_PROOF = "CrossDrop/1 server-proof".toByteArray(Charsets.US_ASCII)
    val LABEL_C2S = "CrossDrop/1 c2s".toByteArray(Charsets.US_ASCII)
    val LABEL_S2C = "CrossDrop/1 s2c".toByteArray(Charsets.US_ASCII)
    val LABEL_SAS = "CrossDrop/1 sas".toByteArray(Charsets.US_ASCII)

    private val TRANSFER_ID = Regex("^[A-Za-z0-9-]{8,64}$")
    private val HEX64 = Regex("^[0-9a-f]{64}$")
    private val HEX32 = Regex("^[0-9a-f]{32}$")

    fun isValidTransferId(id: String) = TRANSFER_ID.matches(id)
    fun isValidSha256Hex(s: String) = HEX64.matches(s)
    fun isValidDeviceId(s: String) = HEX32.matches(s)
}

enum class Platform(val wire: String) {
    ANDROID("android"), MACOS("macos");

    companion object {
        fun fromWire(s: String): Platform =
            entries.firstOrNull { it.wire == s } ?: throw ProtocolException(ErrorCode.BAD_MESSAGE, "unknown platform")
    }
}

/** Wire error codes (§6.4) plus local-only codes that never go on the wire. */
enum class ErrorCode(val wire: String) {
    BAD_FRAME("bad_frame"),
    FRAME_TOO_LARGE("frame_too_large"),
    BAD_MESSAGE("bad_message"),
    UNEXPECTED_MESSAGE("unexpected_message"),
    UNSUPPORTED_VERSION("unsupported_version"),
    AUTH_FAILED("auth_failed"),
    PAIRING_REQUIRED("pairing_required"),
    PAIRING_REJECTED("pairing_rejected"),
    BUSY("busy"),
    NOT_RECEIVING("not_receiving"),
    INTEGRITY_FAILED("integrity_failed"),
    INSUFFICIENT_STORAGE("insufficient_storage"),
    STORAGE_ERROR("storage_error"),
    TIMEOUT("timeout"),
    CANCELLED("cancelled"),
    INTERNAL("internal"),

    // Local only.
    UNREACHABLE("unreachable"),
    CONNECTION_LOST("connection_lost"),
    FILE_UNREADABLE("file_unreadable"),
    PEER_CHANGED_IDENTITY("peer_changed_identity");

    companion object {
        fun fromWire(s: String): ErrorCode = entries.firstOrNull { it.wire == s } ?: INTERNAL
    }
}

/** A protocol-level failure. [remote] is true when the peer reported it. */
class ProtocolException(
    val code: ErrorCode,
    message: String? = null,
    val remote: Boolean = false,
) : Exception(message ?: code.wire)

/** Thrown when the peer rejected an offer with `transfer.reject`. */
class TransferRejectedException(val reason: String) : Exception("rejected: $reason")

internal object B64 {
    fun encode(b: ByteArray): String = Base64.getEncoder().encodeToString(b)
    fun decode(s: String): ByteArray = try {
        Base64.getDecoder().decode(s)
    } catch (e: IllegalArgumentException) {
        throw ProtocolException(ErrorCode.BAD_MESSAGE, "bad base64")
    }
}

fun ByteArray.toHex(): String {
    val chars = "0123456789abcdef"
    val sb = StringBuilder(size * 2)
    for (b in this) {
        val v = b.toInt() and 0xff
        sb.append(chars[v ushr 4]).append(chars[v and 0x0f])
    }
    return sb.toString()
}

fun String.hexToBytes(): ByteArray {
    require(length % 2 == 0) { "odd hex length" }
    return ByteArray(length / 2) { i -> substring(2 * i, 2 * i + 2).toInt(16).toByte() }
}

/** Typed, strict accessors over a decoded control message. */
class Message(val fields: Map<String, Any?>) {
    val type: String = (fields["type"] as? String) ?: throw ProtocolException(ErrorCode.BAD_MESSAGE, "missing type")

    init {
        val v = fields["v"]
        if (v !is Long) throw ProtocolException(ErrorCode.BAD_MESSAGE, "missing v")
    }

    val version: Long get() = fields["v"] as Long

    fun string(key: String, maxBytes: Int = 4096): String {
        val v = fields[key] as? String ?: throw ProtocolException(ErrorCode.BAD_MESSAGE, "missing $key")
        if (v.toByteArray(Charsets.UTF_8).size > maxBytes) throw ProtocolException(ErrorCode.BAD_MESSAGE, "$key too long")
        return v
    }

    fun optString(key: String, maxBytes: Int = 4096): String? =
        if (fields[key] == null) null else string(key, maxBytes)

    fun long(key: String, min: Long = Long.MIN_VALUE, max: Long = Long.MAX_VALUE): Long {
        val v = fields[key] as? Long ?: throw ProtocolException(ErrorCode.BAD_MESSAGE, "missing $key")
        if (v < min || v > max) throw ProtocolException(ErrorCode.BAD_MESSAGE, "$key out of range")
        return v
    }

    fun bool(key: String): Boolean = fields[key] as? Boolean ?: throw ProtocolException(ErrorCode.BAD_MESSAGE, "missing $key")

    fun bytes(key: String, size: Int? = null): ByteArray {
        val b = B64.decode(string(key, 1024))
        if (size != null && b.size != size) throw ProtocolException(ErrorCode.BAD_MESSAGE, "$key has wrong size")
        return b
    }

    fun list(key: String): List<Any?> = fields[key] as? List<Any?> ?: throw ProtocolException(ErrorCode.BAD_MESSAGE, "missing $key")

    fun transferId(): String {
        val id = string("transferId", 64)
        if (!Protocol.isValidTransferId(id)) throw ProtocolException(ErrorCode.BAD_MESSAGE, "bad transferId")
        return id
    }

    companion object {
        fun build(type: String, vararg pairs: Pair<String, Any?>): Map<String, Any?> {
            val m = LinkedHashMap<String, Any?>()
            m["type"] = type
            m["v"] = Protocol.VERSION
            for ((k, v) in pairs) m[k] = v
            return m
        }

        fun parse(bytes: ByteArray): Message = try {
            Message(Json.parseObject(bytes))
        } catch (e: JsonException) {
            throw ProtocolException(ErrorCode.BAD_MESSAGE, "malformed JSON")
        }
    }
}

/** One file entry of a `transfer.offer`. */
data class OfferFile(
    val fileId: Int,
    val name: String,
    val size: Long,
    val mime: String?,
    val sha256: String,
) {
    fun toJson(): Map<String, Any?> = linkedMapOf(
        "fileId" to fileId,
        "name" to name,
        "size" to size,
        "mime" to mime,
        "sha256" to sha256,
    ).also { if (mime == null) it.remove("mime") }

    companion object {
        fun parseOffer(msg: Message): List<OfferFile> {
            val raw = msg.list("files")
            if (raw.isEmpty() || raw.size > Protocol.MAX_FILES) throw ProtocolException(ErrorCode.BAD_MESSAGE, "bad file count")
            val seen = HashSet<Int>()
            return raw.map { entry ->
                @Suppress("UNCHECKED_CAST")
                val m = Message(((entry as? Map<String, Any?>) ?: throw ProtocolException(ErrorCode.BAD_MESSAGE, "bad file entry")) + mapOf("type" to "file", "v" to 1L))
                val fileId = m.long("fileId", 0, (Protocol.MAX_FILES - 1).toLong()).toInt()
                if (!seen.add(fileId)) throw ProtocolException(ErrorCode.BAD_MESSAGE, "duplicate fileId")
                val name = m.string("name", 1024)
                if (name.isEmpty()) throw ProtocolException(ErrorCode.BAD_MESSAGE, "empty name")
                val sha = m.string("sha256", 64)
                if (!Protocol.isValidSha256Hex(sha)) throw ProtocolException(ErrorCode.BAD_MESSAGE, "bad sha256")
                OfferFile(fileId, name, m.long("size", 0, Protocol.MAX_SAFE_SIZE), m.optString("mime", 255), sha)
            }
        }
    }
}

/** Information a device shares about itself during the handshake. */
data class LocalInfo(val name: String, val platform: Platform, val appVersion: String)

/** A verified peer after the handshake. */
data class PeerInfo(
    val deviceId: String,
    val name: String,
    val platform: Platform,
    val appVersion: String,
    val identityKey: ByteArray,
) {
    val fingerprint: String get() = Hashing.sha256(identityKey).toHex()

    override fun equals(other: Any?) = other is PeerInfo && other.deviceId == deviceId && other.identityKey.contentEquals(identityKey)
    override fun hashCode() = deviceId.hashCode()
}

/** Normalises a peer-supplied display name: trims, strips controls, caps at 64 scalar values. */
fun cleanDisplayName(raw: String): String {
    val noControls = raw.filter { !(it.code <= 0x1f || it.code in 0x7f..0x9f) }.trim()
    val cps = noControls.codePoints().limit(64).toArray()
    val out = String(cps, 0, cps.size)
    return out.ifEmpty { "Unknown device" }
}

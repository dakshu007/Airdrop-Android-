package com.crossdrop.pairing

import android.net.Uri
import com.crossdrop.core.Protocol

/**
 * A scanned pairing QR code (protocol §9.4):
 * `crossdrop://pair?v=1&id=<deviceId>&fp=<fingerprint>&t=<token>&n=<name>&p=<port>&h=<host1>,<host2>`.
 * Everything is validated; the code is only a hint until the handshake proves
 * the receiver holds the key whose fingerprint it names.
 */
data class PairingCode(
    val deviceId: String,
    val fingerprint: String,
    val token: String,
    val name: String,
    val port: Int,
    val hosts: List<String>,
) {
    companion object {
        private val HEX64 = Regex("^[0-9a-f]{64}$")
        private val TOKEN = Regex("^[A-Za-z0-9_-]{8,64}$")
        private val HOST = Regex("^[0-9A-Za-z.:%_-]{1,64}$")

        fun parse(raw: String): PairingCode? {
            if (raw.length > 2048 || !raw.startsWith("crossdrop://pair?")) return null
            val uri = runCatching { Uri.parse(raw) }.getOrNull() ?: return null
            fun q(k: String) = uri.getQueryParameter(k)
            if (q("v") != Protocol.VERSION.toString()) return null
            val id = q("id")?.takeIf { Protocol.isValidDeviceId(it) } ?: return null
            val fp = q("fp")?.takeIf { HEX64.matches(it) } ?: return null
            // The device id is derived from the key, so it must agree with the fingerprint.
            if (!fp.startsWith(id)) return null
            val token = q("t")?.takeIf { TOKEN.matches(it) } ?: return null
            val port = q("p")?.toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
            val hosts = (q("h") ?: "").split(',').map { it.trim() }.filter { HOST.matches(it) }.take(8)
            if (hosts.isEmpty()) return null
            val name = (q("n") ?: "Mac").trim().take(64).ifBlank { "Mac" }
            return PairingCode(id, fp, token, name, port, hosts)
        }
    }
}

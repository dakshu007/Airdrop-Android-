package com.crossdrop.rooms

import android.graphics.Bitmap
import android.graphics.Color
import android.util.Base64
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import java.io.ByteArrayOutputStream
import java.net.Inet4Address
import java.net.NetworkInterface

/** Helpers for showing a Drip Room code (§9.9) on this phone. */
object RoomCodes {
    /**
     * This phone's IPv4 addresses on local networks (Wi-Fi, Ethernet, its own hotspot),
     * for the invite's `h` list. Loopback, down and cellular-looking interfaces are skipped.
     */
    fun localAddresses(): List<String> {
        val out = ArrayList<String>()
        val interfaces = runCatching { NetworkInterface.getNetworkInterfaces()?.toList() }.getOrNull() ?: return out
        for (nif in interfaces) {
            val usable = runCatching { nif.isUp && !nif.isLoopback && !nif.isVirtual }.getOrDefault(false)
            if (!usable) continue
            val name = nif.name.lowercase()
            // Mobile data interfaces never carry a local transfer.
            if (name.startsWith("rmnet") || name.startsWith("ccmni") || name.startsWith("pdp") || name.startsWith("dummy")) continue
            for (addr in nif.inetAddresses.toList()) {
                if (addr is Inet4Address && !addr.isLoopbackAddress && (addr.isSiteLocalAddress || addr.isLinkLocalAddress)) {
                    addr.hostAddress?.let { if (it !in out) out.add(it) }
                }
            }
        }
        return out.take(8)
    }

    /** A QR code for [text] as a base64 PNG (no data: prefix), dark modules on white, with a quiet zone. */
    fun qrPng(text: String, sizePx: Int): String {
        val size = sizePx.coerceIn(128, 1024)
        val matrix = QRCodeWriter().encode(
            text, BarcodeFormat.QR_CODE, size, size,
            mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 2),
        )
        val w = matrix.width
        val h = matrix.height
        val pixels = IntArray(w * h)
        for (y in 0 until h) {
            val row = y * w
            for (x in 0 until w) pixels[row + x] = if (matrix.get(x, y)) DARK else Color.WHITE
        }
        val bitmap = Bitmap.createBitmap(pixels, w, h, Bitmap.Config.ARGB_8888)
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        bitmap.recycle()
        return Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    }

    /** Deep green rather than pure black: still high contrast for scanners. */
    private val DARK = Color.rgb(16, 52, 36)
}

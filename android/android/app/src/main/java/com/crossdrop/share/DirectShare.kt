package com.crossdrop.share

import android.content.Context
import android.content.Intent
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.crossdrop.MainActivity
import com.crossdrop.R
import com.crossdrop.core.Platform
import com.crossdrop.core.TrustedPeer

/**
 * Puts recently used paired devices into the Android share sheet's top row
 * (Direct Share). Picking one opens CrossDrop and sends straight to it.
 * Only names of devices the user paired are published, and only to this
 * phone's share sheet.
 */
object DirectShare {
    const val CATEGORY = "com.crossdrop.category.SEND_TO_DEVICE"
    private const val PREFIX = "device:"
    private const val MAX = 4

    fun deviceIdFromShortcut(id: String?): String? = id?.takeIf { it.startsWith(PREFIX) }?.removePrefix(PREFIX)

    fun publish(context: Context, peers: List<TrustedPeer>) {
        val recent = peers.sortedByDescending { it.lastUsedAt ?: it.pairedAt }.take(MAX)
        val shortcuts = recent.mapIndexed { rank, p ->
            ShortcutInfoCompat.Builder(context, PREFIX + p.deviceId)
                .setShortLabel(p.name.take(24))
                .setLongLabel("Send to ${p.name}")
                .setIcon(IconCompat.createWithResource(context, if (p.platform == Platform.MACOS) R.drawable.ic_share_mac else R.drawable.ic_share_phone))
                .setIntent(Intent(Intent.ACTION_DEFAULT, null, context, MainActivity::class.java))
                .setCategories(setOf(CATEGORY))
                .setLongLived(true)
                .setRank(rank)
                .build()
        }
        runCatching {
            val stale = ShortcutManagerCompat.getDynamicShortcuts(context).map { it.id }.filter { id -> shortcuts.none { it.id == id } }
            if (stale.isNotEmpty()) ShortcutManagerCompat.removeDynamicShortcuts(context, stale)
            shortcuts.forEach { ShortcutManagerCompat.pushDynamicShortcut(context, it) }
        }
    }
}

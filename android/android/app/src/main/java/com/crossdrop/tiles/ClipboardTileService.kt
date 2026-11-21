package com.crossdrop.tiles

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.crossdrop.MainActivity
import com.crossdrop.R

/**
 * Optional "Send clipboard" tile. Android lets an app read the clipboard only
 * while it is on screen, so the tile opens CrossDrop, which reads the clipboard
 * once, shows what it found and lets the user pick where to send it. Nothing is
 * read or sent in the background.
 */
class ClipboardTileService : TileService() {
    override fun onStartListening() {
        val tile = qsTile ?: return
        tile.state = Tile.STATE_INACTIVE
        tile.label = getString(R.string.tile_clipboard_label)
        tile.contentDescription = getString(R.string.tile_clipboard_label)
        tile.updateTile()
    }

    override fun onClick() {
        val intent = Intent(this, MainActivity::class.java)
            .setAction(MainActivity.ACTION_SEND_CLIPBOARD)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34) {
            val pi = PendingIntent.getActivity(this, 2, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            startActivityAndCollapse(pi)
        } else {
            @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated")
            startActivityAndCollapse(intent)
        }
    }
}

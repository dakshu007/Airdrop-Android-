package com.crossdrop.tiles

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.crossdrop.MainActivity
import com.crossdrop.R
import com.crossdrop.engine.Engine

/**
 * Optional Quick Settings tile. The user adds it from the Quick Settings editor;
 * the app cannot add it. Turning receiving off works in place. Turning it on
 * opens CrossDrop, because Android does not allow starting the required
 * foreground service from a tile while the app is in the background.
 * The tile never scans or listens on its own.
 */
class ReceiveTileService : TileService() {

    override fun onStartListening() {
        render()
    }

    override fun onClick() {
        val engine = Engine.get(this)
        if (engine.isReceiving) {
            engine.setReceiving(false)
            render()
            return
        }
        val intent = Intent(this, MainActivity::class.java)
            .setAction(MainActivity.ACTION_ENABLE_RECEIVING)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34) {
            val pi = PendingIntent.getActivity(this, 1, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            startActivityAndCollapse(pi)
        } else {
            @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated")
            startActivityAndCollapse(intent)
        }
    }

    private fun render() {
        val tile = qsTile ?: return
        val on = Engine.peek()?.isReceiving ?: false
        tile.state = if (on) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = getString(R.string.tile_label)
        if (Build.VERSION.SDK_INT >= 29) {
            tile.subtitle = getString(if (on) R.string.tile_subtitle_on else R.string.tile_subtitle_off)
        }
        tile.contentDescription = if (on) "CrossDrop receiving on" else "CrossDrop receiving off"
        tile.updateTile()
    }

    companion object {
        /** Asks the system to refresh the tile after receiving changes. */
        fun requestRefresh(context: Context) {
            runCatching { requestListeningState(context, ComponentName(context, ReceiveTileService::class.java)) }
        }
    }
}

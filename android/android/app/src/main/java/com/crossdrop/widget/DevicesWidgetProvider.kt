package com.crossdrop.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import com.crossdrop.MainActivity
import com.crossdrop.R
import com.crossdrop.core.Platform
import com.crossdrop.engine.Engine
import com.crossdrop.storage.TrustRepository

/**
 * Home-screen widget: up to three recently used paired devices (tap: CrossDrop
 * opens with that device chosen, ready to pick files) and a Clipboard button
 * (CrossDrop opens and reads the clipboard once it has focus, like the tile).
 * It never updates on a timer and never touches the network: it is redrawn when
 * paired devices change. Drip Room (temporary) devices are not shown.
 */
class DevicesWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        render(context, manager, ids)
    }

    companion object {
        private val SLOTS = listOf(
            Triple(R.id.slot1, R.id.slot1_icon, R.id.slot1_name),
            Triple(R.id.slot2, R.id.slot2_icon, R.id.slot2_name),
            Triple(R.id.slot3, R.id.slot3_icon, R.id.slot3_name),
        )

        /** Redraws every placed widget (after pairing, forgetting or using a device). */
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context) ?: return
            val ids = runCatching { manager.getAppWidgetIds(ComponentName(context, DevicesWidgetProvider::class.java)) }.getOrNull() ?: return
            if (ids.isNotEmpty()) render(context, manager, ids)
        }

        private fun render(context: Context, manager: AppWidgetManager, ids: IntArray) {
            // Reads paired devices without starting the engine (no networking from a widget update).
            val trust = Engine.peek()?.trust ?: TrustRepository(context.applicationContext)
            val devices = trust.permanent().take(SLOTS.size)
            val views = RemoteViews(context.packageName, R.layout.widget_devices)
            SLOTS.forEachIndexed { index, (slot, icon, label) ->
                val device = devices.getOrNull(index)
                if (device == null) {
                    views.setViewVisibility(slot, View.GONE)
                    return@forEachIndexed
                }
                views.setViewVisibility(slot, View.VISIBLE)
                views.setImageViewResource(icon, if (device.platform == Platform.MACOS) R.drawable.ic_share_mac else R.drawable.ic_share_phone)
                views.setTextViewText(label, device.name)
                views.setContentDescription(slot, context.getString(R.string.widget_send_to, device.name))
                val intent = Intent(context, MainActivity::class.java)
                    .setAction(MainActivity.ACTION_SEND_TO_DEVICE)
                    .putExtra(MainActivity.EXTRA_DEVICE_ID, device.deviceId)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                views.setOnClickPendingIntent(
                    slot,
                    PendingIntent.getActivity(context, 300 + index, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
                )
            }
            views.setViewVisibility(R.id.widget_empty, if (devices.isEmpty()) View.VISIBLE else View.GONE)
            val openEmpty = Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            views.setOnClickPendingIntent(
                R.id.widget_empty,
                PendingIntent.getActivity(context, 310, openEmpty, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
            )
            val clipboard = Intent(context, MainActivity::class.java)
                .setAction(MainActivity.ACTION_SEND_CLIPBOARD)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            views.setOnClickPendingIntent(
                R.id.clipboard,
                PendingIntent.getActivity(context, 311, clipboard, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
            )
            runCatching { manager.updateAppWidget(ids, views) }
        }
    }
}

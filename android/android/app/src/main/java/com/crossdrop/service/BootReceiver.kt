package com.crossdrop.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.crossdrop.engine.Engine

/**
 * After a restart, brings back "My devices only" receiving if the user turned it
 * on. Does nothing otherwise, so CrossDrop stays fully off unless asked.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val prefs = context.getSharedPreferences("crossdrop_prefs", Context.MODE_PRIVATE)
        if (prefs.getString("receiveBase", "off") == "mine") Engine.get(context).restoreReceiving()
    }
}

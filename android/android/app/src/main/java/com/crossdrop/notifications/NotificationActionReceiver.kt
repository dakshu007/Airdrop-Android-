package com.crossdrop.notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.crossdrop.engine.Engine

/**
 * Buttons on CrossDrop notifications: accept or decline an incoming transfer,
 * copy received text, or send a fresh screenshot. Only CrossDrop's own
 * immutable PendingIntents reach it (not exported).
 */
class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val engine = Engine.get(context)
        val id = intent.getStringExtra(EXTRA_ID) ?: return
        when (intent.action) {
            ACCEPT -> engine.respondToOffer(id, true)
            DECLINE -> engine.respondToOffer(id, false)
            COPY -> engine.copyReceivedText(id)
            SEND_SCREENSHOT -> {
                val uri = intent.getStringExtra(EXTRA_VALUE) ?: return
                engine.sendScreenshot(id, uri)
            }
        }
        engine.notifier.cancel(if (intent.action == SEND_SCREENSHOT) "screenshot" else id)
    }

    companion object {
        const val ACCEPT = "com.crossdrop.action.ACCEPT"
        const val DECLINE = "com.crossdrop.action.DECLINE"
        const val COPY = "com.crossdrop.action.COPY"
        const val SEND_SCREENSHOT = "com.crossdrop.action.SEND_SCREENSHOT"
        const val EXTRA_ID = "id"
        const val EXTRA_VALUE = "value"
    }
}

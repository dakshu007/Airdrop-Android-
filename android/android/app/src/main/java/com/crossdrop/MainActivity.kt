package com.crossdrop

import android.content.Intent
import android.os.Bundle
import androidx.core.content.pm.ShortcutManagerCompat
import com.crossdrop.engine.Engine
import com.crossdrop.share.DirectShare
import com.crossdrop.share.SharedFiles
import com.facebook.react.ReactActivity
import com.facebook.react.ReactActivityDelegate
import com.facebook.react.defaults.DefaultNewArchitectureEntryPoint.fabricEnabled
import com.facebook.react.defaults.DefaultReactActivityDelegate

class MainActivity : ReactActivity() {

    override fun getMainComponentName(): String = "CrossDrop"

    override fun createReactActivityDelegate(): ReactActivityDelegate =
        DefaultReactActivityDelegate(this, mainComponentName, fabricEnabled)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A recreated activity must not re-import an old share.
        if (savedInstanceState == null) handleIntent(intent)
    }

    override fun onStart() {
        super.onStart()
        Engine.get(this).setAppVisible(true)
    }

    override fun onStop() {
        Engine.get(this).setAppVisible(false)
        super.onStop()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    /** Set by the "Send clipboard" tile; the clipboard can only be read once we have focus. */
    private var clipboardWanted = false

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && clipboardWanted) {
            clipboardWanted = false
            Engine.get(this).takeClipboard()
        }
    }

    private fun handleIntent(intent: Intent?) {
        val engine = Engine.get(this)
        when (intent?.action) {
            ACTION_ENABLE_RECEIVING -> {
                engine.setReceiving(true)
                return
            }
            ACTION_SEND_CLIPBOARD -> {
                clipboardWanted = true
                if (hasWindowFocus()) onWindowFocusChanged(true)
                return
            }
            // Home-screen widget: a paired device was tapped; the UI opens the picker for it.
            ACTION_SEND_TO_DEVICE -> {
                intent.getStringExtra(EXTRA_DEVICE_ID)?.let { engine.setPendingTarget(it) }
                return
            }
            // A Mac's photo request notification was tapped: show the capture screen.
            ACTION_CAPTURE -> {
                intent.getStringExtra(EXTRA_REQUEST_ID)?.let { engine.focusCapture(it) }
                return
            }
        }
        // Direct Share: the user picked a paired device right in the share sheet.
        val target = DirectShare.deviceIdFromShortcut(intent?.getStringExtra(ShortcutManagerCompat.EXTRA_SHORTCUT_ID))
        val text = SharedFiles.textFromIntent(intent)
        if (text != null) {
            engine.setSharedText(text)
            if (target != null) engine.sendWhenReachable(target, emptyList(), text)
            return
        }
        // Metadata queries can touch other apps' providers; keep them off the UI thread.
        Thread {
            val files = SharedFiles.fromIntent(applicationContext, intent) ?: return@Thread
            engine.setShared(files)
            if (target != null && files.isNotEmpty()) engine.sendWhenReachable(target, files, null)
        }.start()
    }

    companion object {
        const val ACTION_ENABLE_RECEIVING = "com.crossdrop.action.ENABLE_RECEIVING"
        const val ACTION_SEND_CLIPBOARD = "com.crossdrop.action.SEND_CLIPBOARD"
        const val ACTION_SEND_TO_DEVICE = "com.crossdrop.action.SEND_TO_DEVICE"
        const val ACTION_CAPTURE = "com.crossdrop.action.CAPTURE"
        const val EXTRA_DEVICE_ID = "deviceId"
        const val EXTRA_REQUEST_ID = "requestId"
    }
}

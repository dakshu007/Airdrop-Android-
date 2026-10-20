package com.crossdrop

import android.content.Intent
import android.os.Bundle
import com.crossdrop.engine.Engine
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

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        val engine = Engine.get(this)
        if (intent?.action == ACTION_ENABLE_RECEIVING) {
            engine.setReceiving(true)
            return
        }
        // Metadata queries can touch other apps' providers; keep them off the UI thread.
        Thread {
            SharedFiles.fromIntent(applicationContext, intent)?.let { engine.setShared(it) }
        }.start()
    }

    companion object {
        const val ACTION_ENABLE_RECEIVING = "com.crossdrop.action.ENABLE_RECEIVING"
    }
}

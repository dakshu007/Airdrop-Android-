package com.crossdrop.feedback

import android.app.Activity
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.SoundPool
import android.os.Build
import android.view.HapticFeedbackConstants
import com.crossdrop.R
import com.crossdrop.storage.Prefs

/**
 * Optional sound and haptics for moments the user cares about. Both follow
 * the user's CrossDrop settings; haptics also follow the system touch-feedback
 * setting, and the sound only plays when the ringer is on normal.
 */
class Feedback(private val context: Context, private val prefs: Prefs) {
    private var pool: SoundPool? = null
    private var doneSound = 0
    private var loaded = false

    fun perform(kind: String, activity: Activity?) {
        if (prefs.haptics && activity != null) {
            val constant = when (kind) {
                "tick" -> HapticFeedbackConstants.CLOCK_TICK
                "confirm", "done" -> if (Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.VIRTUAL_KEY
                "error" -> if (Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.REJECT else HapticFeedbackConstants.LONG_PRESS
                else -> null
            }
            if (constant != null) {
                activity.runOnUiThread { activity.window?.decorView?.performHapticFeedback(constant) }
            }
        }
        if (kind == "done" && prefs.sound) playDone()
    }

    private fun playDone() {
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        if (audio.ringerMode != AudioManager.RINGER_MODE_NORMAL) return
        synchronized(this) {
            val existing = pool
            if (existing != null) {
                if (loaded) existing.play(doneSound, VOLUME, VOLUME, 1, 0, 1f)
                return
            }
            val created = SoundPool.Builder()
                .setMaxStreams(1)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                .build()
            pool = created
            created.setOnLoadCompleteListener { p, id, status ->
                if (status == 0) {
                    synchronized(this) { loaded = true }
                    p.play(id, VOLUME, VOLUME, 1, 0, 1f)
                }
            }
            doneSound = created.load(context, R.raw.cd_done, 1)
        }
    }

    private companion object {
        const val VOLUME = 0.6f
    }
}

package com.crossdrop.feedback

import android.app.Activity
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.SoundPool
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
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

    /**
     * Haptic heartbeat: a light tick at every 10% of a transfer, on screen or not.
     * Uses the vibrator (the app may be in the background), only when CrossDrop's
     * haptics setting and the system's touch-feedback setting are both on.
     */
    fun heartbeat() = vibrate(VibrationEffect.EFFECT_TICK)

    /** The "done" haptic for a verified transfer while CrossDrop is not on screen (no sound: the notification has one). */
    fun doneInBackground() = vibrate(VibrationEffect.EFFECT_CLICK)

    private fun vibrate(effect: Int) {
        if (!prefs.haptics || !systemHapticsOn()) return
        val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= 31) {
            context.getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
        if (vibrator == null || !vibrator.hasVibrator()) return
        runCatching { vibrator.vibrate(VibrationEffect.createPredefined(effect)) }
    }

    @Suppress("DEPRECATION") // Still the user's touch-feedback switch; the replacement needs API 33.
    private fun systemHapticsOn(): Boolean =
        Settings.System.getInt(context.contentResolver, Settings.System.HAPTIC_FEEDBACK_ENABLED, 1) != 0

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

package com.crossdrop.capture

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import com.crossdrop.engine.Engine
import com.crossdrop.share.SharedFile
import com.crossdrop.share.SharedFiles
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Answers a paired Mac's "take a photo" request (§9.7) with no UI of its own:
 * opens the system camera (ACTION_IMAGE_CAPTURE into a private cache file shared
 * through CrossDrop's FileProvider) or the system Photo Picker (no storage
 * permission), then hands the result to the engine, which sends it back with the
 * request's id. Cancelling leaves the request open until it expires, so the user
 * can try again from the notification or the app.
 */
class CaptureActivity : ComponentActivity() {
    private var requestId: String = ""
    private var photo: File? = null

    private val takePicture = registerForActivityResult(ActivityResultContracts.TakePicture()) { saved ->
        val file = photo
        if (saved && file != null && file.length() > 0) {
            answer(listOf(SharedFile(Uri.fromFile(file).toString(), file.name, file.length(), "image/jpeg")))
        } else {
            file?.delete()
            cancelled()
        }
    }

    private val pickMedia = registerForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(MAX_PICKED)) { uris ->
        if (uris.isEmpty()) {
            cancelled()
            return@registerForActivityResult
        }
        val app = applicationContext
        val id = requestId
        // Metadata queries go to the media provider; keep them off the main thread.
        Thread {
            val files = uris.mapNotNull { uri ->
                // Keeps read access if the answer has to wait for the Mac to be reachable.
                runCatching { app.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
                runCatching { SharedFiles.describe(app, uri) }.getOrNull()
            }
            if (files.isNotEmpty()) Engine.get(app).answerCapture(id, files)
        }.start()
        finish()
    }

    private val askCamera = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) {
            launchCamera()
        } else {
            Toast.makeText(this, "Camera access is off. Pick a photo instead.", Toast.LENGTH_LONG).show()
            launchPicker()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestId = intent.getStringExtra(EXTRA_REQUEST_ID) ?: ""
        savedInstanceState?.getString(STATE_PHOTO)?.let { photo = File(it) }
        if (savedInstanceState != null) return // A result for the launch below is on its way.
        val engine = Engine.get(this)
        if (!engine.hasCaptureRequest(requestId)) {
            Toast.makeText(this, "That request has expired.", Toast.LENGTH_SHORT).show()
            finish()
            return
        }
        engine.openedCapture(requestId)
        if (intent.getStringExtra(EXTRA_MODE) == MODE_PICK) {
            launchPicker()
        } else if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            launchCamera()
        } else {
            // CrossDrop declares CAMERA (for the pairing scanner), so Android requires it for the camera app too.
            askCamera.launch(Manifest.permission.CAMERA)
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        photo?.let { outState.putString(STATE_PHOTO, it.absolutePath) }
    }

    private fun launchCamera() {
        val file = Engine.captureFile(this, requestId)
        photo = file
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        try {
            takePicture.launch(uri)
        } catch (e: ActivityNotFoundException) {
            file.delete()
            photo = null
            Toast.makeText(this, "No camera app is available. Pick a photo instead.", Toast.LENGTH_LONG).show()
            launchPicker()
        }
    }

    private fun launchPicker() {
        try {
            pickMedia.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
        } catch (e: ActivityNotFoundException) {
            Toast.makeText(this, "No photo picker is available.", Toast.LENGTH_LONG).show()
            cancelled()
        }
    }

    /** Closed without an answer: the request stays open (its notification can come back). */
    private fun cancelled() {
        Engine.get(applicationContext).closedCapture(requestId)
        finish()
    }

    private fun answer(files: List<SharedFile>) {
        val app = applicationContext
        val id = requestId
        Thread { Engine.get(app).answerCapture(id, files) }.start()
        finish()
    }

    companion object {
        const val EXTRA_REQUEST_ID = "requestId"
        const val EXTRA_MODE = "mode"
        const val MODE_PHOTO = "photo"
        const val MODE_PICK = "pick"
        private const val STATE_PHOTO = "photo"
        private const val MAX_PICKED = 20

        fun intent(context: Context, requestId: String, mode: String): Intent =
            Intent(context, CaptureActivity::class.java)
                .putExtra(EXTRA_REQUEST_ID, requestId)
                .putExtra(EXTRA_MODE, mode)

        /** File name for a new photo, e.g. "Photo 2026-11-22 at 14.03.11.jpg". */
        fun photoName(at: Long = System.currentTimeMillis()): String =
            "Photo " + SimpleDateFormat("yyyy-MM-dd 'at' HH.mm.ss", Locale.US).format(Date(at)) + ".jpg"
    }
}

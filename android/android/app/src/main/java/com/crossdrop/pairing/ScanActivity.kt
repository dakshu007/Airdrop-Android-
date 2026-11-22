package com.crossdrop.pairing

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Full-screen camera that looks for a CrossDrop pairing or Drip Room QR code. Frames are
 * decoded on the device with ZXing and never stored or sent anywhere. Returns
 * the code's text in [EXTRA_CODE], or RESULT_CANCELED.
 */
class ScanActivity : ComponentActivity() {
    private val analysisThread = Executors.newSingleThreadExecutor()
    private val delivered = AtomicBoolean(false)
    private lateinit var preview: PreviewView
    private lateinit var hint: TextView

    private val askCamera = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) startCamera() else showHint("CrossDrop needs the camera only to read the pairing code. You can allow it in Settings.")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        preview = PreviewView(this).apply { scaleType = PreviewView.ScaleType.FILL_CENTER }
        root.addView(preview, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        root.addView(Viewfinder(this), FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        hint = TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            gravity = Gravity.CENTER
            text = "Point at the code on your Mac\n(CrossDrop › Pair a phone) or at a Drip Room code"
            setPadding(dp(32), 0, dp(32), dp(96))
        }
        root.addView(hint, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM))
        val close = TextView(this).apply {
            text = "Cancel"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
            setPadding(dp(24), dp(20), dp(24), dp(20))
            contentDescription = "Cancel scanning"
            isFocusable = true
            setOnClickListener { finish() }
        }
        root.addView(close, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.START).apply { topMargin = dp(24) })
        setContentView(root)

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) startCamera()
        else askCamera.launch(Manifest.permission.CAMERA)
    }

    private fun startCamera() {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            val provider = runCatching { future.get() }.getOrNull() ?: return@addListener showHint("The camera isn't available.")
            val previewUseCase = Preview.Builder().build().also { it.setSurfaceProvider(preview.surfaceProvider) }
            val reader = MultiFormatReader().apply {
                setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE), DecodeHintType.TRY_HARDER to true))
            }
            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            analysis.setAnalyzer(analysisThread) { image ->
                try {
                    val plane = image.planes[0]
                    val buffer = plane.buffer
                    val data = ByteArray(buffer.remaining()).also { buffer.get(it) }
                    val source = PlanarYUVLuminanceSource(data, plane.rowStride, image.height, 0, 0, image.width, image.height, false)
                    val text = reader.decodeWithState(BinaryBitmap(HybridBinarizer(source))).text
                    onCode(text)
                } catch (e: Exception) {
                    // No code in this frame.
                } finally {
                    reader.reset()
                    image.close()
                }
            }
            runCatching {
                provider.unbindAll()
                provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, previewUseCase, analysis)
            }.onFailure { showHint("The camera isn't available.") }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun onCode(text: String) {
        // Pairing codes (§9.4) and Drip Room codes (§9.9); the engine decides what to do with each.
        if (PairingCode.kindOf(text) == null) {
            runOnUiThread { hint.text = "That's not a CrossDrop code." }
            return
        }
        if (!delivered.compareAndSet(false, true)) return
        runOnUiThread {
            setResult(Activity.RESULT_OK, Intent().putExtra(EXTRA_CODE, text))
            finish()
        }
    }

    private fun showHint(text: String) = runOnUiThread { hint.text = text }

    override fun onDestroy() {
        analysisThread.shutdown()
        super.onDestroy()
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    /** Dims everything but a rounded square in the middle, with a soft mint frame. */
    private class Viewfinder(context: android.content.Context) : View(context) {
        private val dim = Paint().apply { color = Color.argb(140, 0, 0, 0) }
        private val frame = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 3 * resources.displayMetrics.density
            color = Color.rgb(127, 217, 154)
        }

        override fun onDraw(canvas: Canvas) {
            val side = minOf(width, height) * 0.68f
            val left = (width - side) / 2
            val top = (height - side) / 2.4f
            val rect = RectF(left, top, left + side, top + side)
            val radius = 28 * resources.displayMetrics.density
            val hole = Path().apply {
                fillType = Path.FillType.EVEN_ODD
                addRect(0f, 0f, width.toFloat(), height.toFloat(), Path.Direction.CW)
                addRoundRect(rect, radius, radius, Path.Direction.CW)
            }
            canvas.drawPath(hole, dim)
            canvas.drawRoundRect(rect, radius, radius, frame)
        }
    }

    companion object {
        const val EXTRA_CODE = "code"
    }
}

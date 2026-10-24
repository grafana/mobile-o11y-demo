package com.grafana.quickpizza.features.debug

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.PixelCopy
import android.view.Window
import android.view.WindowManager
import androidx.test.platform.app.InstrumentationRegistry
import com.grafana.faro.replay.ReplayMaskGeometry
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.ceil
import kotlin.math.floor
import org.json.JSONArray
import org.json.JSONObject

/** Test-only source capture. No unmasked pixels are encoded, saved or sent to a candidate codec. */
internal class LosslessReplayCapture(private val dir: File) {
    val frames = JSONArray()

    fun capture(
        window: Window,
        geometry: () -> ReplayMaskGeometry?,
        identity: JSONObject,
        stillValid: () -> Boolean = { true },
    ) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val done = CountDownLatch(1)
        val abandoned = AtomicBoolean()
        val pixels = AtomicReference<Bitmap?>()
        val failure = AtomicReference<Throwable?>()
        val metadata = AtomicReference<JSONObject?>()
        val begin = SystemClock.elapsedRealtimeNanos()
        instrumentation.runOnMainSync {
            try {
                check(window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE == 0)
                val decor = window.decorView
                check(decor.isAttachedToWindow && decor.isShown && !decor.isLayoutRequested)
                val before = checkNotNull(geometry()) { "Unsettled mask geometry" }
                check(before.widthPx == decor.width && before.heightPx == decor.height)
                val bitmap = Bitmap.createBitmap(before.widthPx, before.heightPx, Bitmap.Config.ARGB_8888)
                try {
                    PixelCopy.request(window, Rect(0, 0, bitmap.width, bitmap.height), bitmap, { status ->
                        try {
                            check(status == PixelCopy.SUCCESS && !abandoned.get() && stillValid())
                            val after = checkNotNull(geometry())
                            check(before.contentEpoch == after.contentEpoch && before.rectangles == after.rectangles &&
                                before.widthPx == after.widthPx && before.heightPx == after.heightPx)
                            val canvas = Canvas(bitmap)
                            val paint = Paint().apply { color = MASK; isAntiAlias = false }
                            val rects = JSONArray()
                            before.rectangles.forEach { r ->
                                check(listOf(r.left, r.top, r.right, r.bottom).all { it.isFinite() })
                                check(r.left <= r.right && r.top <= r.bottom)
                                val rect = Rect(floor(r.left).toInt().coerceAtLeast(0), floor(r.top).toInt().coerceAtLeast(0),
                                    ceil(r.right).toInt().coerceAtMost(bitmap.width), ceil(r.bottom).toInt().coerceAtMost(bitmap.height))
                                if (!rect.isEmpty) {
                                    canvas.drawRect(rect, paint)
                                    rects.put(JSONArray(listOf(rect.left, rect.top, rect.right, rect.bottom)))
                                    check(bitmap.getPixel(rect.centerX(), rect.centerY()) == MASK)
                                }
                            }
                            metadata.set(JSONObject(identity.toString()).put("originalWidth", bitmap.width)
                                .put("originalHeight", bitmap.height).put("originalMasks", rects))
                            // Ownership transfers only after successful masking and validation.
                            pixels.set(bitmap)
                        } catch (error: Throwable) {
                            bitmap.recycle(); failure.set(error)
                        } finally { done.countDown() }
                    }, Handler(Looper.getMainLooper()))
                } catch (error: Throwable) { bitmap.recycle(); throw error }
            } catch (error: Throwable) { failure.set(error); done.countDown() }
        }
        if (!done.await(10, TimeUnit.SECONDS)) {
            abandoned.set(true)
            // Synchronize with completion without recycling a PixelCopy-owned bitmap.
            instrumentation.runOnMainSync { pixels.getAndSet(null)?.recycle() }
            error("Lossless capture timed out")
        }
        failure.get()?.let { throw it }
        val bitmap = checkNotNull(pixels.getAndSet(null))
        try {
            val index = frames.length()
            val original = File(dir, "original-$index.png")
            original.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
            // Normalize ONCE, before either lossy codec; both consume this exact PNG.
            val factor = minOf(1.0, 800.0 / maxOf(bitmap.width, bitmap.height))
            val width = (bitmap.width * factor).toInt() / 2 * 2
            val height = (bitmap.height * factor).toInt() / 2 * 2
            val source = Bitmap.createScaledBitmap(bitmap, width, height, true)
            try {
                val file = File(dir, "source-$index.png")
                file.outputStream().use { check(source.compress(Bitmap.CompressFormat.PNG, 100, it)) }
                frames.put(checkNotNull(metadata.get()).put("file", file.name).put("original", original.name)
                    .put("width", width).put("height", height)
                    .put("captureAndPngWallMs", (SystemClock.elapsedRealtimeNanos() - begin) / 1_000_000.0))
            } finally { if (source !== bitmap) source.recycle() }
        } finally { bitmap.recycle() }
    }

    fun finish(end: Long, journey: JSONObject) {
        check(frames.length() > 0 && end > frames.getJSONObject(frames.length()-1).getLong("timestamp"))
        File(dir, "source.json").writeText(JSONObject().put("version", 1).put("end", end)
            .put("frames", frames).put("journey", journey).put("input", "masked PNG; shared 800px normalization")
            .put("maskColor", MASK).toString(2))
    }

    companion object { const val MASK: Int = 0xFF5E5E5E.toInt() }
}

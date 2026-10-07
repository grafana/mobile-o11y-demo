package com.grafana.quickpizza.features.debug

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Debug
import android.os.SystemClock
import android.util.Base64
import androidx.annotation.RequiresApi
import com.grafana.faro.replay.ReplayMaskGeometry
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import kotlin.math.abs
import org.json.JSONArray
import org.json.JSONObject

/** Candidate formats from the real recorder's received images. No production transport change. */
@RequiresApi(30)
internal class QuickPizzaFormatRecorder(private val dir: File) {
    private val samples = ArrayList<JSONObject>()
    private val known = LinkedHashMap<String, Pair<String, Int>>(32, .75f, true)
    private var scope = ""
    private var retained = 0

    fun record(frame: JSONObject, captureMs: Double, mainCpuMs: Long, masks: ReplayMaskGeometry) {
        val nextScope = frame.getString("session") + "/" + frame.getString("recording")
        if (scope != nextScope) { known.clear(); retained = 0; scope = nextScope }
        val original = Base64.decode(frame.getString("dataUri").substringAfter(','), Base64.DEFAULT)
        val source = checkNotNull(BitmapFactory.decodeByteArray(original, 0, original.size))
        check(source.width == masks.widthPx && source.height == masks.heightPx)
        var gray = 0
        var inspected = 0
        // Assert interiors of the mask regions in the actual received encoded image.
        // The replay library tests use the same 8-level tolerance for WebP quality 30.
        // Lossy pixels at an edge are not used as a privacy assertion.
        for (rect in masks.rectangles) if (rect.right-rect.left > 8 && rect.bottom-rect.top > 8) {
            val pixel = source.getPixel(((rect.left+rect.right)/2).toInt(), ((rect.top+rect.bottom)/2).toInt())
            check(isGray(pixel, 8)) { "Mask interior mismatch: rect=$rect pixel=${Integer.toHexString(pixel)} epoch=${masks.contentEpoch}" }
        }
        for (y in 0 until source.height step 16) for (x in 0 until source.width step 16) {
            inspected++
            if (isGray(source.getPixel(x, y))) gray++
        }
        val scale = 800.0 / maxOf(source.width, source.height)
        val width = (source.width * scale).toInt() / 2 * 2
        val height = (source.height * scale).toInt() / 2 * 2
        val before = SystemClock.elapsedRealtimeNanos()
        val bitmap = Bitmap.createScaledBitmap(source, width, height, true)
        val stream = ByteArrayOutputStream()
        try { check(bitmap.compress(Bitmap.CompressFormat.WEBP_LOSSY, 30, stream)) }
        finally { if (bitmap !== source) bitmap.recycle(); source.recycle() }
        val normalizationMs = (SystemClock.elapsedRealtimeNanos()-before)/1_000_000.0
        val bytes = stream.toByteArray()
        val reuseStart = SystemClock.elapsedRealtimeNanos()
        // Model the library's 32-entry / 8 MiB confirmed-image policy without changing its wire format.
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        val key = "${frame.getString("screen")}/$width/$height/$digest"
        val old = known[key]
        val file = old?.first ?: "image-${samples.size}.webp"
        if (old == null) {
            File(dir, file).writeBytes(bytes)
            val encodedBytes = 23 + ((bytes.size+2)/3)*4
            if (encodedBytes <= 8*1024*1024) {
                while (known.size >= 32 || retained+encodedBytes > 8*1024*1024) {
                    val iterator = known.entries.iterator()
                    retained -= iterator.next().value.second; iterator.remove()
                }
                known[key] = file to encodedBytes; retained += encodedBytes
            }
        } else check(File(dir, file).readBytes().contentEquals(bytes))
        val reuseMs = (SystemClock.elapsedRealtimeNanos()-reuseStart)/1_000_000.0
        val memory = Debug.MemoryInfo().also { Debug.getMemoryInfo(it) }
        samples += JSONObject().put("timestamp", frame.getLong("timestamp"))
            .put("session", frame.getString("session")).put("recording", frame.getString("recording"))
            .put("screen", frame.getString("screen")).put("file", file).put("reused", old != null)
            .put("width", width).put("height", height).put("imageBytes", bytes.size)
            .put("originalImageBytes", original.size).put("captureMs", captureMs)
            .put("captureMainCpuMs", mainCpuMs).put("normalizationMs", normalizationMs)
            .put("reuseAndLocalWriteMs", reuseMs).put("pssKb", memory.totalPss)
            .put("grayPixelFraction", gray.toDouble()/inspected)
        File(dir, "samples.json").writeText(JSONArray(samples).toString())
    }

    fun finish(endTimestamp: Long, bodyBytes: Long, journey: JSONObject) {
        val clips = ArrayList<JSONObject>()
        var index = 0
        while (index < samples.size) {
            val first = samples[index]
            var end = index+1
            while (end < samples.size && end-index < 5 &&
                samples[end].getString("recording") == first.getString("recording") &&
                samples[end].getInt("width") == first.getInt("width") &&
                samples[end].getInt("height") == first.getInt("height")) end++
            val stop = if (end < samples.size) samples[end].getLong("timestamp") else endTimestamp
            val encoded = BenchmarkVideoEncoder.encode(dir, "clip-${clips.size}.mp4", samples.subList(index, end), stop)
            clips += encoded.put("start", first.getLong("timestamp")).put("end", stop)
                .put("session", first.getString("session")).put("recording", first.getString("recording"))
                .put("firstFrame", index).put("frameCount", end-index)
            index = end
        }
        val report = JSONObject().put("environment", "QuickPizza Android on API 35 emulator; actual recorder and SDK; local receiver")
            .put("frames", samples.size).put("samples", JSONArray(samples)).put("clips", JSONArray(clips))
            .put("endTimestamp", endTimestamp).put("originalFullResolutionFaroBodyBytes", bodyBytes)
            .put("imageBytesWithoutReuse", samples.sumOf { it.getLong("imageBytes") })
            .put("imageBytesWithReuse", samples.filter { !it.getBoolean("reused") }.sumOf { it.getLong("imageBytes") })
            .put("videoBytes", clips.sumOf { it.getLong("bytes") }).put("journey", journey)
            .put("limits", "Actual QuickPizza masked frames sent through current Faro transport to a local test sink. " +
                "Candidate media + compact metadata sizes are not production upload sizes. " +
                "Both use an 800px long edge; native MP4 input is decoded WebP. " +
                "Encoding runs after capture, not concurrently. Emulator only; conservative public-label mask policy.")
        File(dir, "results.json").writeText(report.toString(2))
    }

    private fun isGray(pixel: Int, tolerance: Int = 3): Boolean =
        listOf(16, 8, 0).all { abs(((pixel shr it) and 255)-94) <= tolerance }
}

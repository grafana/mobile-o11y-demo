package com.grafana.quickpizza.features.debug

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaCodecInfo
import android.os.Debug
import android.os.Process
import android.os.SystemClock
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Each candidate is encoded in a fresh instrumentation process from the same persisted PNGs. */
@SdkSuppress(minSdkVersion = 30)
class FairReplayEncoderTest {
    @Test fun encodeCommonSource() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("fairBenchmark") == "true")
        val run = checkNotNull(args.getString("benchmarkRun")).also { require(it.matches(Regex("[a-z0-9-]{1,48}"))) }
        val candidate = checkNotNull(args.getString("candidate")).also { require(it.matches(Regex("[a-z0-9-]{1,60}"))) }
        val dir = File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir, "fair-$run")
        val source = JSONObject(File(dir, "source.json").readText())
        val frames = source.getJSONArray("frames").let { rows -> (0 until rows.length()).map { rows.getJSONObject(it) } }
        val output = File(dir, candidate)
        check(!output.exists() && output.mkdirs()) { "Never overwrite a completed candidate" }
        val started = SystemClock.elapsedRealtimeNanos()
        val cpu = SystemClock.currentThreadTimeMillis()
        val processCpu = Process.getElapsedCpuTime()
        val pssStart = Debug.MemoryInfo().also { Debug.getMemoryInfo(it) }.totalPss
        val report = if (candidate.startsWith("webp-")) images(dir, output, frames, candidate)
            else videos(dir, output, frames, source.getLong("end"), candidate)
        report.put("candidate", candidate).put("end", source.getLong("end"))
            .put("sourceSha256", sha(File(dir, "source.json").readBytes()))
            .put("encodeWallMs", (SystemClock.elapsedRealtimeNanos() - started) / 1_000_000.0)
            .put("encodeCallerCpuMs", SystemClock.currentThreadTimeMillis() - cpu)
            .put("encodeProcessCpuMs", Process.getElapsedCpuTime() - processCpu).put("pssStartKb", pssStart)
        File(output, "result.json").writeText(report.toString(2))
    }

    private fun images(root: File, dir: File, frames: List<JSONObject>, candidate: String): JSONObject {
        val quality = candidate.removePrefix("webp-").let { if (it == "lossless") 100 else it.toInt().also { q -> require(q in 0..100) } }
        val format = if (candidate == "webp-lossless") Bitmap.CompressFormat.WEBP_LOSSLESS else Bitmap.CompressFormat.WEBP_LOSSY
        data class Stored(val file: String, val bytes: ByteArray)
        val cache = LinkedHashMap<String, Stored>(32, .75f, true)
        var scope = ""
        var peakPss = 0
        var allBytes = 0L
        val samples = JSONArray()
        val timings = JSONArray()
        for ((index, frame) in frames.withIndex()) {
            val nextScope = frame.getString("session") + ":" + frame.getString("recording")
            if (scope != nextScope) { cache.clear(); scope = nextScope }
            val start = SystemClock.elapsedRealtimeNanos()
            val cpu = SystemClock.currentThreadTimeMillis()
            val bitmap = checkNotNull(BitmapFactory.decodeFile(File(root, frame.getString("file")).path))
            val bytes = try {
                ByteArrayOutputStream().also { check(bitmap.compress(format, quality, it)) }.toByteArray()
            } finally { bitmap.recycle() }
            allBytes += bytes.size
            val key = frame.getString("screen") + ":" + frame.getInt("width") + ":" + frame.getInt("height") + ":" + sha(bytes)
            val cached = cache[key]?.takeIf { it.bytes.contentEquals(bytes) }
            val file = cached?.file ?: "image-$index.webp"
            if (cached == null) {
                File(dir, file).writeBytes(bytes)
                cache[key] = Stored(file, bytes)
                // Match the existing 32-entry / 8 MiB data-URI payload bound.
                while (cache.size > 32 || cache.values.sumOf { 23L + ((it.bytes.size + 2L) / 3L) * 4L } > 8L * 1024 * 1024) {
                    cache.remove(cache.keys.first())
                }
            }
            samples.put(JSONObject().put("file", file).put("reused", cached != null)
                .put("timestamp", frame.getLong("timestamp")).put("session", frame.getString("session"))
                .put("recording", frame.getString("recording")).put("width", frame.getInt("width"))
                .put("height", frame.getInt("height")).put("screen", frame.getString("screen")))
            timings.put(JSONObject().put("wallMs", (SystemClock.elapsedRealtimeNanos()-start)/1_000_000.0)
                .put("callerCpuMs", SystemClock.currentThreadTimeMillis()-cpu))
            peakPss = maxOf(peakPss, Debug.MemoryInfo().also { Debug.getMemoryInfo(it) }.totalPss)
        }
        return JSONObject().put("kind", "images").put("frames", samples).put("timings", timings)
            .put("allImageBytesWithoutReuse", allBytes).put("peakPssKb", peakPss)
    }

    private fun videos(root: File, dir: File, frames: List<JSONObject>, end: Long, candidate: String): JSONObject {
        val srgb = candidate.startsWith("srgb-")
        val match = checkNotNull(Regex("(vbr|cbr)-(\\d+)-g(\\d+)-c(\\d+)").matchEntire(candidate.removePrefix("srgb-")))
        val mode = if (match.groupValues[1] == "vbr") MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR
            else MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR
        val bitrate = match.groupValues[2].toInt() * 1000
        val keySeconds = match.groupValues[3].toInt()
        val length = match.groupValues[4].toInt()
        require(bitrate in 10_000..2_000_000 && keySeconds in 1..30 && length in 1..30)
        val clips = JSONArray()
        var offset = 0
        var peakPss = 0
        while (offset < frames.size) {
            val first = frames[offset]
            val selected = frames.drop(offset).take(length).takeWhile {
                it.getString("session") == first.getString("session") && it.getString("recording") == first.getString("recording") &&
                    it.getInt("width") == first.getInt("width") && it.getInt("height") == first.getInt("height")
            }
            val boundary = if (offset + selected.size == frames.size) end else frames[offset + selected.size].getLong("timestamp")
            val name = "${dir.name}/clip-${clips.length()}.mp4"
            val clip = FairVideoEncoder.encode(root, name, selected, boundary, bitrate, keySeconds, mode, srgb)
                .put("file", "clip-${clips.length()}.mp4").put("start", first.getLong("timestamp")).put("end", boundary)
                .put("firstFrame", offset).put("frameCount", selected.size)
                .put("session", first.getString("session")).put("recording", first.getString("recording"))
            peakPss = maxOf(peakPss, clip.getInt("peakPssKb"))
            clips.put(clip)
            offset += selected.size
        }
        return JSONObject().put("kind", "video").put("clips", clips).put("peakPssKb", peakPss)
    }

    private fun sha(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}

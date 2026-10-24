package com.grafana.quickpizza.features.debug

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Debug
import android.os.SystemClock
import java.io.File
import java.nio.ByteBuffer
import org.json.JSONObject
import org.json.JSONArray
import android.os.Process

/** Copied from the replay library benchmark at 6e8be87. Test-only H.264 comparison using Android's encoder, not desktop FFmpeg or screenrecord. */
internal object FairVideoEncoder {
    fun encode(dir: File, name: String, frames: List<JSONObject>, endTimestamp: Long, bitrate: Int, keySeconds: Int, mode: Int, srgb: Boolean): JSONObject {
        val started = SystemClock.elapsedRealtimeNanos()
        val cpu = SystemClock.currentThreadTimeMillis()
        val processCpu = Process.getElapsedCpuTime()
        val width = frames.first().getInt("width")
        val height = frames.first().getInt("height")
        val firstTimestamp = frames.first().getLong("timestamp")
        val durationUs = (endTimestamp - firstTimestamp) * 1_000
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        val codecName = codec.name
        val capabilities = codec.codecInfo.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
        if (capabilities.encoderCapabilities?.isBitrateModeSupported(mode) != true) {
            codec.release()
            error("Unsupported bitrate mode: $mode")
        }
        val configuration = JSONObject().put("softwareOnly", codec.codecInfo.isSoftwareOnly)
            .put("hardwareAccelerated", codec.codecInfo.isHardwareAccelerated)
            .put("colorPipeline", if (srgb) "sRGB transfer / BT.709 primaries and matrix / limited range" else "legacy BT.601 / SDR video transfer")
        val keyframes = JSONArray()
        val timestamps = JSONArray()
        val output = File(dir, name)
        val muxer = MediaMuxer(output.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var track = -1
        var startedCodec = false
        var muxing = false
        var next = 0
        var sentEos = false
        var receivedEos = false
        var written = 0
        var peakPss = 0
        try {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_BITRATE_MODE, mode)
                setInteger(MediaFormat.KEY_COLOR_STANDARD, if (srgb) MediaFormat.COLOR_STANDARD_BT709 else MediaFormat.COLOR_STANDARD_BT601_NTSC)
                setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
                // AOSP ColorUtils::kColorTransferSRGB = 2. MediaFormat has no named public constant.
                // This is a test of this codec, not a promise of support on every Android device.
                // Source: frameworks/av/media/module/foundation/include/media/stagefright/foundation/ColorUtils.h
                setInteger(MediaFormat.KEY_COLOR_TRANSFER, if (srgb) 2 else MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
                setInteger(MediaFormat.KEY_FRAME_RATE, 1)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, keySeconds)
            }
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            configuration.put("inputFormat", codec.inputFormat.toString())
            codec.start(); startedCodec = true
            val deadline = SystemClock.elapsedRealtime() + 120_000
            val info = MediaCodec.BufferInfo()
            while (!receivedEos) {
                check(SystemClock.elapsedRealtime() < deadline) { "Encoder timed out" }
                if (!sentEos) {
                    val input = codec.dequeueInputBuffer(10_000)
                    if (input >= 0) {
                        if (next == frames.size) {
                            codec.queueInputBuffer(input, 0, 0, durationUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            sentEos = true
                        } else {
                            val sample = frames[next++]
                            val bitmap = checkNotNull(BitmapFactory.decodeFile(File(dir, sample.getString("file")).path))
                            try {
                                val image = checkNotNull(codec.getInputImage(input)) { "Encoder has no writable YUV image" }
                                fillYuv(image, bitmap, srgb)
                            } finally { bitmap.recycle() }
                            codec.queueInputBuffer(input, 0, width * height * 3 / 2,
                                (sample.getLong("timestamp") - firstTimestamp) * 1_000, 0)
                        }
                    }
                }
                val index = codec.dequeueOutputBuffer(info, 10_000)
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    check(!muxing)
                    if (srgb) {
                        check(codec.outputFormat.getInteger(MediaFormat.KEY_COLOR_STANDARD) == MediaFormat.COLOR_STANDARD_BT709)
                        check(codec.outputFormat.getInteger(MediaFormat.KEY_COLOR_TRANSFER) == 2)
                        check(codec.outputFormat.getInteger(MediaFormat.KEY_COLOR_RANGE) == MediaFormat.COLOR_RANGE_LIMITED)
                    }
                    configuration.put("outputFormat", codec.outputFormat.toString())
                    track = muxer.addTrack(codec.outputFormat); muxer.start(); muxing = true
                } else if (index >= 0) {
                    try {
                        if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                            check(muxing)
                            muxer.writeSampleData(track, checkNotNull(codec.getOutputBuffer(index)), info)
                            timestamps.put(info.presentationTimeUs)
                            if (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0) keyframes.put(written)
                            written++
                        }
                        receivedEos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    } finally { codec.releaseOutputBuffer(index, false) }
                }
                val memory = Debug.MemoryInfo().also { Debug.getMemoryInfo(it) }
                peakPss = maxOf(peakPss, memory.totalPss)
            }
            check(written == frames.size)
            // Preserve the last still frame's hold time, including an idle tail.
            val end = MediaCodec.BufferInfo().apply { set(0, 0, durationUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM) }
            muxer.writeSampleData(track, ByteBuffer.allocate(0), end)
            muxer.stop(); muxing = false
        } finally {
            try {
                try { if (startedCodec) codec.stop() } finally { codec.release() }
            } finally {
                try { if (muxing) muxer.stop() } finally { muxer.release() }
            }
        }
        return JSONObject().put("file", name).put("bytes", output.length()).put("codec", codecName)
            .put("bitrate", bitrate).put("keySeconds", keySeconds).put("bitrateMode", mode)
            .put("configuration", configuration).put("keyframeIndexes", keyframes).put("presentationTimesUs", timestamps)
            .put("encodeProcessCpuMs", Process.getElapsedCpuTime() - processCpu).put("width", width).put("height", height)
            .put("encodeWallMs", (SystemClock.elapsedRealtimeNanos() - started) / 1_000_000.0)
            .put("encodeCallerCpuMs", SystemClock.currentThreadTimeMillis() - cpu).put("peakPssKb", peakPss)
    }

    private fun fillYuv(image: Image, bitmap: Bitmap, srgb: Boolean) {
        val width = bitmap.width
        val height = bitmap.height
        val pixels = IntArray(width * height)
        bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
        val planes = image.planes
        check(planes.size == 3 && image.width == width && image.height == height)
        for (y in 0 until height) for (x in 0 until width) {
            val rgb = pixels[y * width + x]
            val red = (rgb shr 16) and 255
            val green = (rgb shr 8) and 255
            val blue = rgb and 255
            val luma = if (srgb) ((11966 * red + 40254 * green + 4064 * blue + 32768) shr 16) + 16
                else ((66 * red + 129 * green + 25 * blue + 128) shr 8) + 16
            planes[0].buffer.put(y * planes[0].rowStride + x * planes[0].pixelStride, luma.coerceIn(0, 255).toByte())
            if (y % 2 == 0 && x % 2 == 0) {
                // Average all four chroma samples; do not favour the top-left coloured pixel.
                var r = 0; var g = 0; var b = 0
                for (dy in 0..1) for (dx in 0..1) {
                    val pixel = pixels[(y + dy) * width + x + dx]
                    r += (pixel shr 16) and 255; g += (pixel shr 8) and 255; b += pixel and 255
                }
                r = (r + 2) / 4; g = (g + 2) / 4; b = (b + 2) / 4
                val u = if (srgb) ((-6596 * r - 22188 * g + 28784 * b + 32768) shr 16) + 128
                    else ((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128
                val v = if (srgb) ((28784 * r - 26145 * g - 2639 * b + 32768) shr 16) + 128
                    else ((112 * r - 94 * g - 18 * b + 128) shr 8) + 128
                planes[1].buffer.put(y / 2 * planes[1].rowStride + x / 2 * planes[1].pixelStride, u.coerceIn(0, 255).toByte())
                planes[2].buffer.put(y / 2 * planes[2].rowStride + x / 2 * planes[2].pixelStride, v.coerceIn(0, 255).toByte())
            }
        }
    }
}

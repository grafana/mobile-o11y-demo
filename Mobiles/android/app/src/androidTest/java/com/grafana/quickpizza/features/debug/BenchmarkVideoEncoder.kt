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

/** Copied from the replay library benchmark at 6e8be87. Test-only H.264 comparison using Android's encoder, not desktop FFmpeg or screenrecord. */
internal object BenchmarkVideoEncoder {
    fun encode(dir: File, name: String, frames: List<JSONObject>, endTimestamp: Long): JSONObject {
        val started = SystemClock.elapsedRealtimeNanos()
        val cpu = SystemClock.currentThreadTimeMillis()
        val width = frames.first().getInt("width")
        val height = frames.first().getInt("height")
        val firstTimestamp = frames.first().getLong("timestamp")
        val durationUs = (endTimestamp - firstTimestamp) * 1_000
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        val codecName = codec.name
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
                setInteger(MediaFormat.KEY_BIT_RATE, 75_000)
                setInteger(MediaFormat.KEY_FRAME_RATE, 1)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 5)
            }
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start(); startedCodec = true
            val deadline = SystemClock.elapsedRealtime() + 30_000
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
                                fillYuv(image, bitmap)
                            } finally { bitmap.recycle() }
                            codec.queueInputBuffer(input, 0, width * height * 3 / 2,
                                (sample.getLong("timestamp") - firstTimestamp) * 1_000, 0)
                        }
                    }
                }
                val index = codec.dequeueOutputBuffer(info, 10_000)
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    check(!muxing)
                    track = muxer.addTrack(codec.outputFormat); muxer.start(); muxing = true
                } else if (index >= 0) {
                    try {
                        if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                            check(muxing)
                            muxer.writeSampleData(track, checkNotNull(codec.getOutputBuffer(index)), info)
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
            .put("bitrate", 75_000).put("width", width).put("height", height)
            .put("encodeWallMs", (SystemClock.elapsedRealtimeNanos() - started) / 1_000_000.0)
            .put("encodeCallerCpuMs", SystemClock.currentThreadTimeMillis() - cpu).put("peakPssKb", peakPss)
    }

    private fun fillYuv(image: Image, bitmap: Bitmap) {
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
            val luma = ((66 * red + 129 * green + 25 * blue + 128) shr 8) + 16
            planes[0].buffer.put(y * planes[0].rowStride + x * planes[0].pixelStride, luma.coerceIn(0, 255).toByte())
            if (y % 2 == 0 && x % 2 == 0) {
                val u = ((-38 * red - 74 * green + 112 * blue + 128) shr 8) + 128
                val v = ((112 * red - 94 * green - 18 * blue + 128) shr 8) + 128
                planes[1].buffer.put(y / 2 * planes[1].rowStride + x / 2 * planes[1].pixelStride, u.coerceIn(0, 255).toByte())
                planes[2].buffer.put(y / 2 * planes[2].rowStride + x / 2 * planes[2].pixelStride, v.coerceIn(0, 255).toByte())
            }
        }
    }
}

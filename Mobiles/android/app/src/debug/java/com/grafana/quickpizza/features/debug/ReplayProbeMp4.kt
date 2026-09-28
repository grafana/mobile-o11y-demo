package com.grafana.quickpizza.features.debug

import android.graphics.Bitmap
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import androidx.annotation.RequiresApi
import java.io.File

/**
 * Debug encoder. Writes one short H.264 mp4 of the already-masked bitmap.
 * A file over 1 MiB is deleted so the capture can try a smaller frame.
 */
@RequiresApi(26)
object ReplayProbeMp4 {
    const val MAX_BYTES = 1 * 1024 * 1024
    private const val FRAME_COUNT = 5
    private const val FRAME_DURATION_US = 1_000_000L
    private val maxWidths = intArrayOf(720, 540, 360, 240)

    fun write(source: Bitmap, dest: File): EncodedClip {
        dest.parentFile?.mkdirs()
        var lastError: Exception? = null
        for (maxWidth in maxWidths) {
            val scaled = scaleEven(source, maxWidth)
            try {
                encode(scaled, dest)
                val bytes = dest.length()
                if (bytes in 1..MAX_BYTES) {
                    return EncodedClip(scaled.width, scaled.height, bytes)
                }
                dest.delete()
                lastError = IllegalStateException("clip is ${bytes} bytes")
            } catch (error: Exception) {
                dest.delete()
                lastError = error
            } finally {
                if (scaled !== source && !scaled.isRecycled) scaled.recycle()
            }
        }
        dest.delete()
        throw IllegalStateException("clip stayed over 1 MiB", lastError)
    }

    private fun encode(bitmap: Bitmap, dest: File) {
        val width = bitmap.width
        val height = bitmap.height
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        val color = colorFormat(codec)
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, color)
            setInteger(MediaFormat.KEY_BIT_RATE, 200_000)
            setInteger(MediaFormat.KEY_FRAME_RATE, ReplayProbeJson.FRAME_RATE)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 5)
        }
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
        val muxer = MediaMuxer(dest.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var track = -1
        var muxerStarted = false
        try {
            val yuv = toYuv(bitmap, color)
            repeat(FRAME_COUNT) { frame ->
                val input = codec.dequeueInputBuffer(10_000)
                if (input < 0) error("encoder did not accept a frame")
                val buffer = codec.getInputBuffer(input) ?: error("encoder input buffer missing")
                buffer.clear()
                if (buffer.capacity() < yuv.size) error("encoder input buffer is smaller than the frame")
                buffer.put(yuv)
                codec.queueInputBuffer(input, 0, yuv.size, frame * FRAME_DURATION_US, 0)
                val drained = drain(codec, muxer, track, muxerStarted, false)
                track = drained.track
                muxerStarted = drained.started
            }
            val eos = codec.dequeueInputBuffer(10_000)
            if (eos >= 0) {
                codec.queueInputBuffer(eos, 0, 0, FRAME_COUNT * FRAME_DURATION_US, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            }
            drain(codec, muxer, track, muxerStarted, true)
        } finally {
            if (muxerStarted) {
                muxer.stop()
            }
            muxer.release()
            codec.stop()
            codec.release()
        }
    }

    private fun colorFormat(codec: MediaCodec): Int {
        val formats = codec.codecInfo.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC).colorFormats
        val preferred = intArrayOf(
            MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar,
        )
        return preferred.firstOrNull { it in formats } ?: formats.first()
    }

    private data class Drain(val track: Int, val started: Boolean)

    private fun drain(
        codec: MediaCodec,
        muxer: MediaMuxer,
        track: Int,
        started: Boolean,
        endOfStream: Boolean,
    ): Drain {
        var currentTrack = track
        var muxerStarted = started
        var wroteSample = false
        val info = MediaCodec.BufferInfo()
        var spins = 0
        while (spins < 64) {
            val output = codec.dequeueOutputBuffer(info, 10_000)
            when {
                output == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (wroteSample && !endOfStream) return Drain(currentTrack, muxerStarted)
                    spins += 1
                }
                output == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    if (muxerStarted) error("encoder format changed after the muxer started")
                    currentTrack = muxer.addTrack(codec.outputFormat)
                    muxer.start()
                    muxerStarted = true
                }
                output >= 0 -> {
                    val encoded = codec.getOutputBuffer(output)
                    if (encoded != null && info.size > 0 && muxerStarted) {
                        encoded.position(info.offset)
                        encoded.limit(info.offset + info.size)
                        muxer.writeSampleData(currentTrack, encoded, info)
                        wroteSample = true
                    }
                    val end = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    codec.releaseOutputBuffer(output, false)
                    if (end || (wroteSample && !endOfStream)) return Drain(currentTrack, muxerStarted)
                }
                else -> spins += 1
            }
        }
        if (endOfStream) error("encoder did not finish the clip")
        return Drain(currentTrack, muxerStarted)
    }

    private fun scaleEven(source: Bitmap, maxWidth: Int): Bitmap {
        val targetWidth = maxWidth.coerceAtMost(source.width).coerceAtLeast(2)
        var width = if (targetWidth % 2 == 0) targetWidth else targetWidth - 1
        var height = (source.height.toLong() * width / source.width).toInt().coerceAtLeast(2)
        if (height % 2 != 0) height -= 1
        if (width == source.width && height == source.height) return source
        return Bitmap.createScaledBitmap(source, width, height, true)
    }

    private fun toYuv(bitmap: Bitmap, color: Int): ByteArray {
        val width = bitmap.width
        val height = bitmap.height
        val argb = IntArray(width * height)
        bitmap.getPixels(argb, 0, width, 0, 0, width, height)
        val yuv = ByteArray(width * height * 3 / 2)
        val planar = color == MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar
        var yIndex = 0
        var uIndex = width * height
        var vIndex = uIndex + (width * height) / 4
        for (row in 0 until height) {
            for (col in 0 until width) {
                val pixel = argb[row * width + col]
                val r = (pixel shr 16) and 0xff
                val g = (pixel shr 8) and 0xff
                val b = pixel and 0xff
                yuv[yIndex++] = (((66 * r + 129 * g + 25 * b + 128) shr 8) + 16).coerceIn(0, 255).toByte()
                if (row % 2 == 0 && col % 2 == 0) {
                    val u = (((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128).coerceIn(0, 255).toByte()
                    val v = (((112 * r - 94 * g - 18 * b + 128) shr 8) + 128).coerceIn(0, 255).toByte()
                    if (planar) {
                        yuv[uIndex++] = u
                        yuv[vIndex++] = v
                    } else {
                        yuv[uIndex++] = u
                        yuv[uIndex++] = v
                    }
                }
            }
        }
        return yuv
    }

    data class EncodedClip(val width: Int, val height: Int, val bytes: Long)
}

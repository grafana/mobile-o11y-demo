package com.grafana.quickpizza.features.debug

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.PixelCopy
import androidx.annotation.RequiresApi
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import java.io.File
import kotlin.coroutines.resume
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

private const val TAG = "ReplayProbe"

/**
 * Debug-only probe. Writes two short H.264 clips and the player event list.
 * Does not call the collector.
 */
@Composable
fun ReplayProbeCaptureButton(screenName: String, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    var armed by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(armed) {
        if (!armed) return@LaunchedEffect
        // Let the button leave the tree and the next frame draw before PixelCopy.
        withFrameNanos { }
        withFrameNanos { }
        val activity = context.findActivity()
        status = ReplayProbeCapture.capture(activity, screenName)
        armed = false
    }

    if (armed) return

    Column(modifier = modifier) {
        OutlinedButton(
            onClick = { armed = true },
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(12.dp),
        ) {
            Text("Capture")
        }
        status?.let { message ->
            Text(
                text = message,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

object ReplayProbeCapture {
    suspend fun capture(activity: Activity, screenName: String): String {
        if (Build.VERSION.SDK_INT < 26) {
            return "Capture needs Android 8 (API 26) or newer"
        }
        val clipFile = try {
            ReplayProbeJson.fileFor(screenName)
        } catch (_: IllegalArgumentException) {
            return "Capture only supports Login and Home"
        }
        val maskRegions = ReplayProbeMasker.collect(activity)
        val bitmap = copyWindow(activity) ?: return "Could not capture the window"
        return try {
            withContext(Dispatchers.IO) {
                ReplayProbeMasker.paint(bitmap, maskRegions)
                val partial = File(activity.filesDir, "${ReplayProbeJson.CLIPS_DIR}/$clipFile.partial")
                val encoded = try {
                    ReplayProbeMp4.write(bitmap, partial)
                } catch (error: Exception) {
                    partial.delete()
                    Log.w(TAG, "clip encode failed", error)
                    return@withContext "Capture failed: clip must stay at or under 1 MiB"
                }
                val dest = File(activity.filesDir, "${ReplayProbeJson.CLIPS_DIR}/$clipFile")
                if (!partial.renameTo(dest)) {
                    partial.copyTo(dest, overwrite = true)
                    partial.delete()
                }
                activity.getExternalFilesDir(null)?.let { dir ->
                    val copy = File(dir, "${ReplayProbeJson.CLIPS_DIR}/$clipFile")
                    copy.parentFile?.mkdirs()
                    dest.copyTo(copy, overwrite = true)
                }
                val json = synchronized(this@ReplayProbeCapture) {
                    val existing = File(activity.filesDir, ReplayProbeJson.FILE_NAME)
                        .takeIf { it.isFile }
                        ?.readText()
                    val next = ReplayProbeJson.upsert(
                        existingJson = existing,
                        screenName = screenName,
                        width = encoded.width,
                        height = encoded.height,
                        timestamp = System.currentTimeMillis(),
                    )
                    writeAtomic(File(activity.filesDir, ReplayProbeJson.FILE_NAME), next)
                    writeAtomic(
                        File(activity.filesDir, ReplayProbeJson.PAYLOAD_FILE_NAME),
                        ReplayProbeJson.payload(next),
                    )
                    activity.getExternalFilesDir(null)?.let { dir ->
                        writeAtomic(File(dir, ReplayProbeJson.FILE_NAME), next)
                        writeAtomic(File(dir, ReplayProbeJson.PAYLOAD_FILE_NAME), ReplayProbeJson.payload(next))
                    }
                    next
                }
                val frames = ReplayProbeJson.frameCount(json)
                val pull =
                    "mkdir -p /tmp/replay-probe/clips && " +
                        "adb exec-out run-as ${activity.packageName} cat files/${ReplayProbeJson.FILE_NAME} > /tmp/replay-probe/replay-probe.json && " +
                        "adb exec-out run-as ${activity.packageName} cat files/${ReplayProbeJson.CLIPS_DIR}/0001.mp4 > /tmp/replay-probe/clips/0001.mp4 && " +
                        "adb exec-out run-as ${activity.packageName} cat files/${ReplayProbeJson.CLIPS_DIR}/0002.mp4 > /tmp/replay-probe/clips/0002.mp4"
                Log.i(TAG, pull)
                "Saved $screenName as $clipFile (${encoded.bytes} bytes, $frames clips, masked). Pull: $pull"
            }
        } finally {
            bitmap.recycle()
        }
    }

    @RequiresApi(26)
    private suspend fun copyWindow(activity: Activity): Bitmap? = suspendCancellableCoroutine { cont ->
        val view = activity.window.decorView
        val width = view.width
        val height = view.height
        if (width <= 0 || height <= 0) {
            cont.resume(null)
            return@suspendCancellableCoroutine
        }
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        PixelCopy.request(
            activity.window,
            bitmap,
            { result ->
                if (result == PixelCopy.SUCCESS) {
                    cont.resume(bitmap)
                } else {
                    bitmap.recycle()
                    Log.w(TAG, "PixelCopy result=$result")
                    cont.resume(null)
                }
            },
            Handler(Looper.getMainLooper()),
        )
    }

    private fun writeAtomic(dest: File, json: String) {
        dest.parentFile?.mkdirs()
        val tmp = File(dest.parentFile, dest.name + ".tmp")
        tmp.writeText(json)
        if (!tmp.renameTo(dest)) {
            dest.writeText(json)
            tmp.delete()
        }
    }

}

private fun Context.findActivity(): Activity {
    var current: Context = this
    while (current is ContextWrapper) {
        if (current is Activity) return current
        current = current.baseContext
    }
    error("Replay probe capture requires an Activity")
}

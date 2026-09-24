package com.grafana.quickpizza.features.debug

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Base64
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
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.coroutines.resume
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

private const val TAG = "ReplayProbe"
private const val JPEG_OR_WEBP_QUALITY = 30

/**
 * Debug-only probe. Writes a player array to the app files dir. Does not call the collector.
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
        val maskRegions = ReplayProbeMasker.collect(activity)
        val bitmap = copyWindow(activity) ?: return "Could not capture the window"
        return try {
            withContext(Dispatchers.IO) {
                ReplayProbeMasker.paint(bitmap, maskRegions)
                val encoded = encode(bitmap)
                val json = synchronized(this@ReplayProbeCapture) {
                    val existing = File(activity.filesDir, ReplayProbeJson.FILE_NAME)
                        .takeIf { it.isFile }
                        ?.readText()
                    val next = ReplayProbeJson.upsert(
                        existingJson = existing,
                        screenName = screenName,
                        width = bitmap.width,
                        height = bitmap.height,
                        dataUri = encoded.dataUri,
                        timestamp = System.currentTimeMillis(),
                    )
                    writeAtomic(File(activity.filesDir, ReplayProbeJson.FILE_NAME), next)
                    activity.getExternalFilesDir(null)?.let { dir ->
                        writeAtomic(File(dir, ReplayProbeJson.FILE_NAME), next)
                    }
                    next
                }
                val frames = ReplayProbeJson.frameCount(json)
                val pull =
                    "adb exec-out run-as ${activity.packageName} cat files/${ReplayProbeJson.FILE_NAME} > /tmp/replay-probe-android.json"
                Log.i(TAG, pull)
                "Saved $screenName ($frames frames, masked). Pull: $pull"
            }
        } finally {
            bitmap.recycle()
        }
    }

    @RequiresApi(26)
    private fun encode(bitmap: Bitmap): EncodedFrame {
        val webp = Build.VERSION.SDK_INT >= 30
        val format = if (webp) Bitmap.CompressFormat.WEBP_LOSSY else Bitmap.CompressFormat.JPEG
        val mime = if (webp) "image/webp" else "image/jpeg"
        val bytes = ByteArrayOutputStream()
        bitmap.compress(format, JPEG_OR_WEBP_QUALITY, bytes)
        val b64 = Base64.encodeToString(bytes.toByteArray(), Base64.NO_WRAP)
        return EncodedFrame("data:$mime;base64,$b64")
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

    private data class EncodedFrame(val dataUri: String)
}

private fun Context.findActivity(): Activity {
    var current: Context = this
    while (current is ContextWrapper) {
        if (current is Activity) return current
        current = current.baseContext
    }
    error("Replay probe capture requires an Activity")
}

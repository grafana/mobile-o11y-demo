package com.grafana.quickpizza.features.debug

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.os.Debug
import android.os.Process
import android.os.SystemClock
import android.view.View
import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import com.grafana.faro.replay.ReplayMaskGeometry
import com.grafana.faro.replay.ReplayMaskRect
import java.io.File
import kotlin.math.sin
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** A separate, explicitly synthetic workload; it is not a new QuickPizza screen or mask policy. */
@SdkSuppress(minSdkVersion = 30)
class FairMotionComparisonTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun fiveMinuteMotion() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("fairBenchmark") == "true")
        val seconds = (args.getString("benchmarkSeconds") ?: "300").toInt().also { require(it in 10..300) }
        val run = checkNotNull(args.getString("benchmarkRun")).also { require(it.matches(Regex("[a-z0-9-]{1,48}"))) }
        val dir = File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir, "fair-$run")
        check(!dir.exists() && dir.mkdirs())
        val masks = linkedMapOf<String, ReplayMaskRect>()
        var epoch = 0L
        var publicTop = 0f
        var publicBottom = 0f
        lateinit var animation: PublicMotionView
        fun Modifier.masked(id: String) = onGloballyPositioned {
            val r = it.boundsInWindow()
            val next = ReplayMaskRect(r.left, r.top, r.right, r.bottom)
            if (masks.put(id, next) != next) epoch++
        }
        compose.setContent {
            MaterialTheme {
                Column(Modifier.fillMaxSize().background(Color.White).padding(16.dp).onGloballyPositioned {
                    val r = it.boundsInWindow(); publicTop = r.top; publicBottom = r.bottom
                }) {
                    Text("Replay format test", fontSize = 22.sp)
                    Text("Public demo data only", fontSize = 14.sp)
                    BasicTextField("synthetic@example.invalid", {}, Modifier.fillMaxWidth().height(30.dp).masked("email"))
                    BasicTextField("test-password-123", {}, Modifier.fillMaxWidth().height(30.dp).masked("password"))
                    AndroidView(factory = { PublicMotionView(it).also { v -> animation = v } },
                        modifier = Modifier.fillMaxWidth().height(185.dp))
                    Column(Modifier.weight(1f).fillMaxWidth().testTag("public-list")
                        .verticalScroll(rememberScrollState())) {
                        repeat(60) { index ->
                            Column(Modifier.fillMaxWidth().background(if (index % 2 == 0) Color(0xffedf2f6) else Color.White)
                                .padding(8.dp)) {
                                Text("Pizza ${index.toString().padStart(2, '0')} · Tomato and basil", fontSize = 15.sp)
                                Text("Order ${1000 + index}   EUR ${10 + index}.50   Ready in 12 min", fontSize = 12.sp)
                                Row(Modifier.fillMaxWidth()) {
                                    repeat(12) { cell ->
                                        Box(Modifier.weight(1f).height(14.dp).background(Color(
                                            0xff000000 or (((index * 19 + cell * 41) % 220 + 25).toLong() shl 16) or
                                                (((index * 53 + cell * 29) % 220 + 25).toLong() shl 8) or
                                                ((index * 37 + cell * 71) % 220 + 25).toLong())))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        compose.waitForIdle()
        val source = LosslessReplayCapture(dir)
        val samples = JSONArray()
        val started = SystemClock.elapsedRealtime()
        val cpu = Process.getElapsedCpuTime()
        val mainCpu = compose.runOnIdle { SystemClock.currentThreadTimeMillis() }
        try {
            for (second in 0 until seconds) {
                SystemClock.sleep((started + second * 1000 - SystemClock.elapsedRealtime()).coerceAtLeast(0))
                val phase = second * 300 / seconds
                compose.runOnIdle { animation.moving = phase >= 100 }
                if (phase in 15..99 || phase >= 200) {
                    compose.onNodeWithTag("public-list").performTouchInput {
                        if ((phase / 20) % 2 == 0) swipeUp(startY = height * .75f, endY = height * .55f, durationMillis = 180)
                        else swipeDown(startY = height * .4f, endY = height * .6f, durationMillis = 180)
                    }
                    epoch++
                }
                compose.waitForIdle()
                source.capture(compose.activity.window, {
                    val decor = compose.activity.window.decorView
                    if (masks.size != 2 || publicBottom <= publicTop) null else ReplayMaskGeometry(
                        decor.width, decor.height, epoch, masks.values.toList() + listOf(
                            ReplayMaskRect(0f, 0f, decor.width.toFloat(), publicTop),
                            ReplayMaskRect(0f, publicBottom, decor.width.toFloat(), decor.height.toFloat())))
                }, JSONObject().put("session", "synthetic-motion-session").put("recording", "source-${second / 100}")
                    .put("screen", "SyntheticMotion").put("timestamp", System.currentTimeMillis()).put("phase", phase))
                val mem = Debug.MemoryInfo().also { Debug.getMemoryInfo(it) }
                samples.put(JSONObject().put("second", second).put("pssKb", mem.totalPss))
            }
            SystemClock.sleep((started + seconds * 1000 - SystemClock.elapsedRealtime()).coerceAtLeast(0))
            source.finish(System.currentTimeMillis(), JSONObject().put("kind", "synthetic Compose scroll and native animation")
                .put("elapsedMs", SystemClock.elapsedRealtime() - started).put("samples", samples)
                .put("processCpuMs", Process.getElapsedCpuTime() - cpu)
                .put("mainThreadCpuMs", compose.runOnIdle { SystemClock.currentThreadTimeMillis() } - mainCpu))
        } finally { compose.runOnIdle { animation.moving = false } }
    }
}

/** Public generated content animates on vsync; Compose's idling clock does not fake its frames. */
private class PublicMotionView(context: Context) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val started = SystemClock.elapsedRealtime()
    var moving = false
        set(value) { if (field != value) { field = value; invalidate() } }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        canvas.drawColor(0xfff3f5f7.toInt())
        val progress = if (moving) (SystemClock.elapsedRealtime() - started) / 700.0 else 0.0
        for (row in 0 until 8) {
            paint.color = android.graphics.Color.rgb(35 + row * 23, 80 + row * 17, 200 - row * 19)
            val left = ((sin(progress + row * .8) + 1) * .30 * width).toFloat()
            val top = height * (.18f + row * .085f)
            canvas.drawRect(left, top, left + width * .3f, top + height * .065f, paint)
        }
        paint.color = android.graphics.Color.BLACK
        paint.textSize = 14 * resources.displayMetrics.density
        canvas.drawText("Order 0042 · Delivery progress", 8f, paint.textSize + 4f, paint)
        if (moving && isAttachedToWindow) postInvalidateOnAnimation()
    }
}

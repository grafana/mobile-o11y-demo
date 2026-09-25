package com.grafana.quickpizza.features.debug

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.os.Debug
import android.os.Process
import android.os.SystemClock
import android.util.Log
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.espresso.Espresso.closeSoftKeyboard
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import com.grafana.faro.replay.CaptureRequestResult
import com.grafana.faro.replay.MaskOptions
import com.grafana.quickpizza.MainActivity
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.After
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Opt-in, local-only journey through the actual app, with an identical no-capture baseline. */
@SdkSuppress(minSdkVersion = 30)
class QuickPizzaFormatComparisonTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private var tracing = false

    @After fun stopProfiling() {
        if (tracing) {
            tracing = false
            Debug.stopMethodTracing()
        }
    }

    @Test fun fiveMinuteJourney() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("quickPizzaBenchmark") == "true")
        val seconds = (args.getString("benchmarkSeconds") ?: "300").toInt()
        require(seconds in 10..300)
        val run = checkNotNull(args.getString("benchmarkRun"))
        require(run.matches(Regex("[a-z0-9-]{1,48}")))
        val capturing = args.getString("benchmarkBaseline") != "true"
        check(request("/_benchmark/start", JSONObject().put("run", run)).getString("kind") == "local-quickpizza-benchmark")
        compose.waitForIdle()
        compose.runOnIdle {
            checkNotNull(compose.activity.otelService.openTelemetryRum)
            checkNotNull(ReplayJourney.recorder)
        }
        val dir = File(compose.activity.filesDir, "format-comparison-$run")
        check(!dir.exists() && dir.mkdirs()) { "Use a fresh run name to preserve evidence" }
        val recorder = QuickPizzaFormatRecorder(dir)
        val appSamples = JSONArray()
        val actions = JSONArray()
        if (args.getString("benchmarkTrace") == "true") {
            Debug.startMethodTracingSampling(File(dir, "capture-methods.trace").path, 32*1024*1024, 1_000)
            tracing = true
        }
        val cpuStart = Process.getElapsedCpuTime()
        val mainStart = compose.runOnIdle { SystemClock.currentThreadTimeMillis() }
        val started = SystemClock.elapsedRealtime()
        var screen = "Home"
        var previousPhase = -1
        for (second in 0 until seconds) {
            SystemClock.sleep((started+second*1_000-SystemClock.elapsedRealtime()).coerceAtLeast(0))
            val phase = second*300/seconds
            fun reached(at: Int) = at > previousPhase && at <= phase
            if (reached(20) || reached(210)) {
                compose.onNodeWithContentDescription("Profile").performClick()
                compose.onNodeWithText("Username").performTextInput("benchmark@example.invalid")
                compose.onNodeWithText("Password").performTextInput("synthetic-benchmark-password")
                closeSoftKeyboard()
                screen = "Login"
                actions.put(JSONObject().put("phase", phase).put("action", "Login with synthetic fields"))
            }
            if (reached(50) || reached(230)) {
                compose.onNodeWithContentDescription("Back").performClick(); screen = "Home"
                actions.put(JSONObject().put("phase", phase).put("action", "Home"))
            }
            if (reached(55) || reached(235)) {
                compose.onNodeWithText("Customize Your Pizza").performScrollTo().performClick()
                actions.put(JSONObject().put("phase", phase).put("action", "Expand customization"))
            }
            if (phase in 60..79 || phase in 240..259) scroll(true)
            if (phase in 80..99 || phase in 260..279) scroll(false)
            if (reached(105)) {
                compose.onNodeWithTag("replay.error").performScrollTo().performClick()
                compose.onNodeWithTag("replay.error.visible").assertExists()
                actions.put(JSONObject().put("phase", phase).put("action", "Handled checkout error"))
            }
            if (reached(150) || reached(180)) {
                val landscape = phase < 180
                compose.activityRule.scenario.onActivity { it.requestedOrientation = if (landscape)
                    ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE else ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
                compose.waitUntil(10_000) { compose.activity.resources.configuration.orientation ==
                    if (landscape) Configuration.ORIENTATION_LANDSCAPE else Configuration.ORIENTATION_PORTRAIT }
                actions.put(JSONObject().put("phase", phase).put("action", if (landscape) "Landscape" else "Portrait"))
            }
            compose.waitForIdle()
            // Let platform IME/orientation animations settle, beyond Compose idleness.
            if (listOf(20, 50, 55, 105, 150, 180, 210, 230, 235).any { reached(it) }) {
                SystemClock.sleep(300); compose.waitForIdle()
            }
            if (capturing && (reached(100) || reached(200))) compose.runOnIdle { ReplayJourney.recorder!!.stop() }
            if (capturing) {
                val geometry = compose.runOnIdle { checkNotNull(ReplayJourney.geometry.snapshot(
                    compose.activity.window, screen, MaskOptions(maskAllText = false))) }
                val before = SystemClock.elapsedRealtimeNanos()
                val mainBefore = compose.runOnIdle { SystemClock.currentThreadTimeMillis() }
                compose.runOnIdle { assertEquals(CaptureRequestResult.REQUESTED, ReplayJourney.capture(screen)) }
                var received = request("/_benchmark/latest")
                val deadline = SystemClock.elapsedRealtime()+10_000
                while (received.getInt("count") < second+1 && SystemClock.elapsedRealtime() < deadline) {
                    SystemClock.sleep(10); received = request("/_benchmark/latest")
                }
                assertEquals("One accepted real frame per request", second+1, received.getInt("count"))
                val wall = (SystemClock.elapsedRealtimeNanos()-before)/1_000_000.0
                val mainCpu = compose.runOnIdle { SystemClock.currentThreadTimeMillis() }-mainBefore
                val frame = received.getJSONObject("frame")
                assertEquals(screen, frame.getString("screen"))
                recorder.record(frame, wall, mainCpu, geometry)
            }
            val mem = Debug.MemoryInfo().also { Debug.getMemoryInfo(it) }
            appSamples.put(JSONObject().put("second", second).put("elapsedMs", SystemClock.elapsedRealtime()-started)
                .put("processCpuMs", Process.getElapsedCpuTime()-cpuStart)
                .put("mainThreadCpuMs", compose.runOnIdle { SystemClock.currentThreadTimeMillis() }-mainStart)
                .put("pssKb", mem.totalPss))
            previousPhase = phase
            if (second%30 == 0) Log.i("QuickPizzaBenchmark", "$run $second/$seconds seconds")
        }
        SystemClock.sleep((started+seconds*1_000-SystemClock.elapsedRealtime()).coerceAtLeast(0))
        val end = compose.runOnIdle { checkNotNull(compose.activity.otelService.replaySession.epochMillis()) }
        val journey = JSONObject().put("run", run).put("capturing", capturing)
            .put("elapsedMs", SystemClock.elapsedRealtime()-started).put("actions", actions)
            .put("samples", appSamples).put("processCpuMs", Process.getElapsedCpuTime()-cpuStart)
            .put("mainThreadCpuMs", compose.runOnIdle { SystemClock.currentThreadTimeMillis() }-mainStart)
        compose.runOnIdle { ReplayJourney.recorder!!.stop() }
        File(dir, "journey.json").writeText(journey.toString(2))
        stopProfiling()
        if (capturing) recorder.finish(end, request("/_benchmark/latest").getLong("bodyBytes"), journey)
        Log.i("QuickPizzaBenchmark", "$run complete; capturing=$capturing; seconds=$seconds")
    }

    private fun scroll(up: Boolean) {
        compose.onNode(hasScrollAction() and hasAnyDescendant(hasTestTag("replay.capture"))).performTouchInput {
            if (up) swipeUp(startY=height*.65f, endY=height*.59f, durationMillis=500)
            else swipeDown(startY=height*.45f, endY=height*.51f, durationMillis=500)
        }
    }

    private fun request(path: String, body: JSONObject? = null): JSONObject {
        val connection = URL("http://127.0.0.1:18002$path").openConnection() as HttpURLConnection
        connection.connectTimeout = 2_000; connection.readTimeout = 2_000
        try {
            if (body != null) {
                connection.requestMethod = "POST"; connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.use { it.write(body.toString().toByteArray()) }
            }
            check(connection.responseCode == 200) { "Local benchmark API: ${connection.responseCode}" }
            return JSONObject(connection.inputStream.bufferedReader().use { it.readText() })
        } finally { connection.disconnect() }
    }
}

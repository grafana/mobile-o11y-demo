package com.grafana.quickpizza.features.debug

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Color
import android.media.MediaMetadataRetriever
import android.os.SystemClock
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.Lifecycle
import androidx.test.espresso.Espresso.closeSoftKeyboard
import androidx.test.platform.app.InstrumentationRegistry
import com.grafana.quickpizza.MainActivity
import java.io.ByteArrayInputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.GZIPInputStream
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Real Activity, SDK and MP4 transport into a loopback sink; not a Grafana persistence test. */
class AutomaticReplayCaptureTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    private val colorChecks = JSONArray()

    @Test fun settledChangesUploadMaskedClipsWithoutCaptureClicks() {
        val args = InstrumentationRegistry.getArguments()
        org.junit.Assume.assumeTrue(
            "Run automatic_smoke.py with a disposable emulator and synthetic loopback configuration",
            args.getString("automaticReplaySmoke") == "true",
        )
        compose.waitForIdle()
        compose.runOnIdle { assertNotNull("Configure the local replay integration", ReplayJourney.recorder) }
        assertEquals("No recording before explicit start", 0, clips().size)
        compose.onNodeWithTag("replay.start").performScrollTo().performClick()
        val first = awaitClip(0)
        assertMasked(first, emptyList(), requireVisibleLabel = true, compareAppColors = true)
        val steps = JSONArray().put(step("start-home", first))
        drainAndAssertStable()
        val idleCount = clips().size
        val idleStarted = SystemClock.elapsedRealtime()
        SystemClock.sleep(10_000)
        assertEquals("Idle time must not create duplicate frames", idleCount, clips().size)
        val idleMillis = SystemClock.elapsedRealtime() - idleStarted

        var count = clips().size
        compose.onNodeWithContentDescription("About", useUnmergedTree = true).performTouchInput { click() }
        val about = awaitClip(count)
        assertMasked(about, emptyList(), compareAppColors = true)
        steps.put(step("navigate-about", about))
        count = clips().size
        compose.onNodeWithContentDescription("Debug", useUnmergedTree = true).performTouchInput { click() }
        val debug = awaitClip(count)
        assertMasked(debug, emptyList())
        steps.put(step("navigate-debug", debug))
        drainAndAssertStable()
        count = clips().size
        compose.onNodeWithText("Config", substring = false).performScrollTo().performClick()
        SystemClock.sleep(1_200)
        assertEquals("Unknown Config surface must not be recorded", count, clips().size)
        androidx.test.espresso.Espresso.pressBack()
        steps.put(step("return-from-unsupported-config", awaitClip(count)))
        count = clips().size
        compose.onNodeWithContentDescription("Home", useUnmergedTree = true).performTouchInput { click() }
        steps.put(step("return-home", awaitClip(count)))
        count = clips().size
        compose.onNodeWithContentDescription("Profile").performClick()
        val login = awaitClip(count)
        steps.put(step("navigate-login", login))
        assertEquals(first.getString("session"), login.getString("session"))
        compose.onNodeWithText("Username").performTextInput("replay-user@example.invalid")
        compose.onNodeWithText("Password").performTextInput("synthetic-replay-password")
        compose.waitForIdle()
        SystemClock.sleep(700)
        val keyboardCount = clips().size
        compose.runOnIdle { ReplayJourney.changed("Login") }
        SystemClock.sleep(800)
        assertEquals("Open keyboard must suppress capture", keyboardCount, clips().size)
        closeSoftKeyboard()
        compose.waitForIdle()
        // The sign-in state change, rather than a capture control, records populated masked inputs.
        val username = compose.onNodeWithText("Username").fetchSemanticsNode().boundsInRoot
        val password = compose.onNodeWithText("Password").fetchSemanticsNode().boundsInRoot
        count = clips().size
        compose.onNodeWithText("Sign In").performClick()
        val populated = awaitClip(count)
        assertMasked(populated, listOf(username, password))
        steps.put(step("populated-login-state", populated))
        drainAndAssertStable()

        count = clips().size
        compose.onNodeWithContentDescription("Back").performClick()
        steps.put(step("navigate-home", awaitClip(count)))
        count = clips().size
        compose.onNodeWithText("Customize Your Pizza").performClick()
        steps.put(step("expand-customization", awaitClip(count)))
        compose.onNodeWithText("Custom name (optional)").performScrollTo().assertIsDisplayed()
        drainAndAssertStable()
        val beforeInput = compose.onNodeWithText("Custom name (optional)").fetchSemanticsNode().boundsInRoot
        val maskScroll = compose.onAllNodes(hasScrollAction()).onFirst()
        val range = maskScroll.fetchSemanticsNode().config[SemanticsProperties.VerticalScrollAxisRange]
        val oldOffset = range.value()
        val delta = if (range.maxValue() - oldOffset >= 100f) 100f else -minOf(100f, oldOffset)
        assertTrue("The expanded screen must offer actual scrolling", kotlin.math.abs(delta) >= 1f)
        count = clips().size
        maskScroll.performSemanticsAction(SemanticsActions.ScrollBy) { scrollBy -> scrollBy(0f, delta) }
        compose.waitForIdle()
        val newOffset = maskScroll.fetchSemanticsNode().config[SemanticsProperties.VerticalScrollAxisRange].value()
        assertTrue("The moving-mask test must move actual content", kotlin.math.abs(newOffset - oldOffset) >= 1f)
        val movedInput = compose.onNodeWithText("Custom name (optional)").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        assertTrue("Input bounds must move with the content", kotlin.math.abs(movedInput.top - beforeInput.top) >= 1f)
        val moved = awaitClip(count)
        assertMasked(moved, listOf(movedInput))
        steps.put(step("scrolled-input-mask", moved))
        compose.onNodeWithText("QuickPizza has your back!").performScrollTo()
        drainAndAssertStable()
        count = clips().size
        val scrollContainer = compose.onAllNodes(hasScrollAction()).onFirst()
        val beforeScroll = scrollContainer.fetchSemanticsNode().config[SemanticsProperties.VerticalScrollAxisRange].value()
        compose.onNodeWithTag("replay.error").performScrollTo()
        val afterScroll = scrollContainer.fetchSemanticsNode().config[SemanticsProperties.VerticalScrollAxisRange].value()
        assertTrue("The scroll step must move actual screen content", afterScroll > beforeScroll)
        steps.put(step("scroll-home", awaitClip(count)))
        assertStable("Settled scrolling must not keep capturing")

        count = clips().size
        compose.onNodeWithTag("replay.error").performClick()
        compose.onNodeWithTag("replay.error.visible").performScrollTo().assertIsDisplayed()
        val errorBounds = compose.onNodeWithTag("replay.error.visible").fetchSemanticsNode().boundsInRoot
        val error = awaitClip(count)
        assertMasked(error, emptyList(), visibleRegions = listOf(errorBounds))
        captureEmulatorEvidence("automatic-emulator-error.png")
        lateinit var identity: ReplayDemoError
        compose.runOnIdle {
            identity = checkNotNull(ReplayJourney.lastError)
            assertEquals(identity.sessionId, error.getString("session"))
        }
        steps.put(step("visible-checkout-error", error))
        drainAndAssertStable()

        count = clips().size
        compose.activityRule.scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
        compose.waitUntil(10_000) { compose.activity.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE }
        compose.waitForIdle()
        val rotated = awaitClip(count) { receipt ->
            val data = receipt.getJSONArray("events").getJSONObject(0).getJSONObject("data")
            data.getInt("width") > data.getInt("height")
        }
        // Rotation emits a newly masked frame and keeps the host telemetry session.
        assertTrue(rotated.getJSONArray("events").getJSONObject(0).getJSONObject("data").getInt("width") >
            rotated.getJSONArray("events").getJSONObject(0).getJSONObject("data").getInt("height"))
        assertEquals(first.getString("session"), rotated.getString("session"))
        steps.put(step("rotation", rotated))
        drainAndAssertStable()

        count = clips().size
        compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
        SystemClock.sleep(2_000)
        assertEquals("No accepted capture in background", count, clips().size)
        compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
        steps.put(step("foreground-resume", awaitClip(count)))
        drainAndAssertStable()

        // Stop via the UI. Subsequent navigation must not silently re-arm replay.
        compose.onNodeWithTag("replay.stop").performScrollTo().performClick()
        SystemClock.sleep(1_500)
        count = clips().size
        compose.onNodeWithContentDescription("Profile").performClick()
        compose.onNodeWithText("Username").assertExists()
        SystemClock.sleep(2_000)
        assertEquals("Stopped replay must not restart on navigation", count, clips().size)
        compose.onNodeWithContentDescription("Back").performClick()
        SystemClock.sleep(1_500)
        assertEquals("Stopped replay must remain stopped on return", count, clips().size)

        // The SDK uses its normal disk batching. Keep the process alive until these exact
        // signals reached the receiver; unrelated startup telemetry is not sufficient evidence.
        val exportedError = awaitExportedError(identity)
        assertEquals("Telemetry drain must not restart stopped replay", count, clips().size)
        val all = clips()
        assertTrue(all.all { it.getBoolean("multipart") && it.getInt("clipBytes") > 0 })
        for (receipt in all) assertMasked(receipt, emptyList())
        val report = JSONObject().put("kind", "real Android emulator to local MP4 sink")
            .put("steps", steps).put("acceptedClips", all.size).put("manualCaptureClicks", 0)
            .put("backgroundSuppressed", true).put("stopDoesNotRestart", true)
            .put("idleCaptureLoopAbsent", true).put("populatedInputMaskChecked", true)
            .put("idleMillis", idleMillis).put("colorChecks", colorChecks)
            .put("keyboardSuppressed", true).put("unsupportedConfigSuppressed", true)
            .put("movedInputMaskChecked", true).put("exportedError", exportedError)
            .put("errors", JSONArray().put(JSONObject().put("sessionId", identity.sessionId)
                .put("traceId", identity.traceId).put("spanId", identity.spanId)
                .put("triggeredAtEpochMillis", identity.triggeredAtEpochMillis).put("sampled", identity.sampled)))
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        File(context.filesDir, "automatic-replay-smoke.json").writeText(report.toString(2))
    }

    private fun awaitExportedError(identity: ReplayDemoError): JSONObject {
        fun hexBytes(value: String) = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        fun ByteArray.containsBytes(expected: ByteArray): Boolean =
            size >= expected.size && (0..size - expected.size).any { offset ->
                expected.indices.all { this[offset + it] == expected[it] }
            }
        val trace = hexBytes(identity.traceId)
        val span = hexBytes(identity.spanId)
        val message = "Replay demo: checkout unavailable".toByteArray(Charsets.UTF_8)
        val checked = mutableSetOf<Int>()
        var traceRequest: Int? = null
        var logRequest: Int? = null
        val started = SystemClock.elapsedRealtime()
        while (SystemClock.elapsedRealtime() - started < 60_000) {
            val receipts = JSONArray(get("http://127.0.0.1:18002/_test/receipts").toString(Charsets.UTF_8))
            for (index in 0 until receipts.length()) {
                val receipt = receipts.getJSONObject(index)
                val request = receipt.getInt("requestIndex")
                val path = receipt.optString("path")
                if (request in checked || receipt.optInt("status") !in 200..299 ||
                    !receipt.optString("contentType").contains("protobuf") ||
                    (!path.endsWith("/v1/traces") && !path.endsWith("/v1/logs"))) continue
                val body = get("http://127.0.0.1:18002/_test/body/$request")
                val decoded = if (receipt.optString("contentEncoding").equals("gzip", ignoreCase = true)) {
                    GZIPInputStream(ByteArrayInputStream(body)).use { it.readBytes() }
                } else body
                checked.add(request)
                if (decoded.containsBytes(trace) && decoded.containsBytes(span) && decoded.containsBytes(message)) {
                    if (path.endsWith("/v1/traces")) traceRequest = request else logRequest = request
                }
            }
            if (traceRequest != null && logRequest != null) {
                // These byte checks prove delivery before teardown. Backend verification separately
                // decodes/query-matches session, span and trace; this is not a storage claim.
                return JSONObject().put("traceRequestIndex", traceRequest).put("logRequestIndex", logRequest)
                    .put("waitMillis", SystemClock.elapsedRealtime() - started)
                    .put("exactTraceSpanAndMessageOnWire", true)
            }
            SystemClock.sleep(250)
        }
        error("The exact checkout telemetry did not export within 60s: trace=$traceRequest log=$logRequest checked=${checked.size}")
    }

    private fun step(name: String, receipt: JSONObject): JSONObject = JSONObject()
        .put("name", name).put("receiptIndex", receipt.getInt("index"))
        .put("session", receipt.getString("session"))

    private fun awaitClip(after: Int, predicate: (JSONObject) -> Boolean = { true }): JSONObject {
        var found: JSONObject? = null
        compose.waitUntil(20_000) {
            clips().drop(after).firstOrNull(predicate)?.also { found = it } != null
        }
        return checkNotNull(found)
    }

    private fun assertStable(message: String) {
        val count = clips().size
        SystemClock.sleep(2_000)
        assertEquals(message, count, clips().size)
    }

    private fun drainAndAssertStable() {
        // Allow the trailing loading/error state to settle before testing inactivity.
        SystemClock.sleep(1_200)
        assertStable("An idle screen must not create additional MP4 requests")
    }

    private fun clips(): List<JSONObject> {
        val receipts = JSONArray(get("http://127.0.0.1:18002/_automatic/receipts").toString(Charsets.UTF_8))
        return (0 until receipts.length()).map { receipts.getJSONObject(it) }
            .filter { it.getBoolean("multipart") }
    }

    private fun get(url: String): ByteArray {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 2_000
        connection.readTimeout = 5_000
        return try { connection.inputStream.use { it.readBytes() } } finally { connection.disconnect() }
    }

    private fun captureEmulatorEvidence(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val screenshot = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        try {
            File(instrumentation.targetContext.filesDir, name).outputStream().use {
                assertTrue(screenshot.compress(Bitmap.CompressFormat.PNG, 100, it))
            }
        } finally {
            screenshot.recycle()
        }
    }

    private fun assertMasked(
        receipt: JSONObject,
        controls: List<Rect>,
        requireVisibleLabel: Boolean = false,
        visibleRegions: List<Rect> = emptyList(),
        compareAppColors: Boolean = false,
    ) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = File(context.cacheDir, "automatic-mask-check.mp4")
        file.writeBytes(get(receipt.getString("clipUrl")))
        val retriever = MediaMetadataRetriever()
        var bitmap: Bitmap? = null
        try {
            retriever.setDataSource(file.path)
            val decoded = checkNotNull(retriever.getFrameAtTime(0)) { "Accepted MP4 must decode on Android" }
            bitmap = decoded
            val data = receipt.getJSONArray("events").getJSONObject(0).getJSONObject("data")
            assertEquals(data.getInt("width"), decoded.width)
            assertEquals(data.getInt("height"), decoded.height)
            fun maskPixel(x: Int, y: Int) {
                val pixel = decoded.getPixel(x.coerceIn(0, decoded.width - 1), y.coerceIn(0, decoded.height - 1))
                for (channel in listOf(Color.red(pixel), Color.green(pixel), Color.blue(pixel))) {
                    assertTrue("Masked pixel must stay near solid gray after H.264 encoding: $channel", channel in 78..110)
                }
            }
            maskPixel(5, 5)
            if (compareAppColors) {
                val actual = checkNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
                try {
                    assertEquals(decoded.width, actual.width)
                    assertEquals(decoded.height, actual.height)
                    var compared = 0
                    var matched = 0
                    for (y in 30 until actual.height - 30 step 4) for (x in 20 until actual.width - 20 step 4) {
                        val expected = actual.getPixel(x, y)
                        val channels = listOf(Color.red(expected), Color.green(expected), Color.blue(expected))
                        if (channels.max() - channels.min() < 40) continue
                        // Flat colored interiors avoid glyph/edge changes from lossy H.264.
                        if (listOf(actual.getPixel(x - 2, y), actual.getPixel(x + 2, y),
                            actual.getPixel(x, y - 2), actual.getPixel(x, y + 2)).any { neighbor ->
                                kotlin.math.abs(Color.red(neighbor) - Color.red(expected)) > 5 ||
                                    kotlin.math.abs(Color.green(neighbor) - Color.green(expected)) > 5 ||
                                    kotlin.math.abs(Color.blue(neighbor) - Color.blue(expected)) > 5
                            }) continue
                        val pixel = decoded.getPixel(x, y)
                        compared++
                        if (kotlin.math.abs(Color.red(pixel) - Color.red(expected)) <= 25 &&
                            kotlin.math.abs(Color.green(pixel) - Color.green(expected)) <= 25 &&
                            kotlin.math.abs(Color.blue(pixel) - Color.blue(expected)) <= 25) matched++
                    }
                    assertTrue("Compare actual colored app pixels, not only non-gray output", compared > 100)
                    assertTrue("Decoded MP4 must retain app colors: $matched/$compared", matched.toDouble() / compared > .90)
                    colorChecks.put(JSONObject().put("receiptIndex", receipt.getInt("index"))
                        .put("comparedPixels", compared).put("matchedPixels", matched).put("channelTolerance", 25))
                    File(context.filesDir, "automatic-source-${receipt.getInt("index")}.png").outputStream().use {
                        assertTrue(actual.compress(Bitmap.CompressFormat.PNG, 100, it))
                    }
                } finally { actual.recycle() }
            }
            if (requireVisibleLabel) {
                var visible = 0
                for (y in 0 until decoded.height step 4) for (x in 0 until decoded.width step 4) {
                    val pixel = decoded.getPixel(x, y)
                    if (listOf(Color.red(pixel), Color.green(pixel), Color.blue(pixel)).any { it !in 60..125 }) visible++
                }
                assertTrue("The capture must retain public labels rather than pass as an all-gray frame", visible > 10)
            }
            for (region in visibleRegions) {
                var visible = 0
                for (y in region.top.toInt().coerceAtLeast(0) until region.bottom.toInt().coerceAtMost(decoded.height) step 2) {
                    for (x in region.left.toInt().coerceAtLeast(0) until region.right.toInt().coerceAtMost(decoded.width) step 2) {
                        val pixel = decoded.getPixel(x, y)
                        if (listOf(Color.red(pixel), Color.green(pixel), Color.blue(pixel)).any { it !in 60..125 }) visible++
                    }
                }
                assertTrue("The visible public error label must survive in the received MP4", visible > 10)
            }
            File(context.filesDir, "automatic-frame-${receipt.getInt("index")}.png").outputStream().use {
                assertTrue(decoded.compress(Bitmap.CompressFormat.PNG, 100, it))
            }
            for (bounds in controls) {
                for (fractionY in listOf(.25f, .5f, .75f)) for (fractionX in listOf(.25f, .5f, .75f)) {
                    maskPixel((bounds.left + bounds.width * fractionX).toInt(), (bounds.top + bounds.height * fractionY).toInt())
                }
            }
        } finally {
            bitmap?.recycle()
            retriever.release()
            file.delete()
        }
    }
}

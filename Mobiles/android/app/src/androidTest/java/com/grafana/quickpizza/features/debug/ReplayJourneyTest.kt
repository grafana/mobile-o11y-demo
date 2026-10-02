package com.grafana.quickpizza.features.debug

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.os.SystemClock
import android.util.Log
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.Lifecycle
import androidx.test.espresso.Espresso.closeSoftKeyboard
import androidx.test.platform.app.InstrumentationRegistry
import com.grafana.faro.replay.CaptureRequestResult
import com.grafana.quickpizza.MainActivity
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** The real QuickPizza Activity and released OTel SDK; every replay POST reaches the real collector. */
class ReplayJourneyTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test fun loginHomeErrorRotationAndRealSessionExpiry() {
        compose.waitForIdle()
        compose.runOnIdle {
            assertNotNull("Configure the local OTLP endpoint before running", compose.activity.otelService.openTelemetryRum)
            assertNotNull("Configure OTLP_ENDPOINT before running", ReplayJourney.recorder)
        }
        val first = capture("Home")
        compose.onNodeWithContentDescription("Profile").performClick()
        compose.onNodeWithText("Username").performTextInput("replay-user@example.invalid")
        compose.onNodeWithText("Password").performTextInput("synthetic-replay-password")
        closeSoftKeyboard()
        val login = capture("Login")
        compose.onNodeWithContentDescription("Back").performClick()
        val beforeFirstError = receipts().length()
        compose.onNodeWithTag("replay.error").performScrollTo().performClick()
        compose.onNodeWithTag("replay.error.visible").assertExists()
        val firstError = errorIdentity()
        val error = capture("Home")
        assertEquals(error.getString("session"), firstError.sessionId)
        awaitTelemetryExports(beforeFirstError)
        for (frame in listOf(login, error)) {
            assertEquals(first.getString("session"), frame.getString("session"))
            assertEquals(first.getString("recording"), frame.getString("recording"))
        }

        compose.activityRule.scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
        compose.waitUntil(10_000) { compose.activity.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE }
        compose.waitForIdle()
        val landscape = capture("Home")
        assertTrue(landscape.getInt("width") > landscape.getInt("height"))
        assertEquals(first.getString("session"), landscape.getString("session"))
        assertEquals(first.getString("recording"), landscape.getString("recording"))

        compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            assertEquals(CaptureRequestResult.NO_FOREGROUND_WINDOW, ReplayJourney.recorder!!.capture("Home"))
        }
        compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
        compose.waitForIdle()
        val resumed = capture("Home")

        // Local-only test config shortens the REAL SDK maximum lifetime to 30 seconds.
        // Wait through expiry without resolving its session from replay or a polling timer.
        SystemClock.sleep(31_000)
        val beforeNextError = receipts().length()
        compose.onNodeWithTag("replay.error").performScrollTo().performClick()
        val nextError = errorIdentity()
        val next = capture("Home")
        assertNotEquals(first.getString("session"), next.getString("session"))
        assertNotEquals(first.getString("recording"), next.getString("recording"))
        assertEquals(next.getString("session"), nextError.sessionId)
        assertNotEquals(firstError.traceId, nextError.traceId)
        // Keep the app process alive through normal SDK batching. An instrumentation teardown can
        // otherwise kill the last error/trace before its exporter sends anything.
        awaitTelemetryExports(beforeNextError)

        val beforeStop = frames().size
        compose.runOnIdle {
            assertEquals(CaptureRequestResult.REQUESTED, ReplayJourney.recorder!!.capture("Home"))
            ReplayJourney.recorder!!.stop()
            assertEquals(CaptureRequestResult.NOT_STARTED, ReplayJourney.recorder!!.capture("Home"))
        }
        compose.waitForIdle()
        SystemClock.sleep(500)
        assertEquals("stop must discard the unfinished capture", beforeStop, frames().size)

        val report = JSONObject().put("firstSession", first.getString("session"))
            .put("nextSession", next.getString("session"))
            .put("frames", JSONArray(listOf(first, login, error, landscape, resumed, next)))
            .put("rotationPreservedSession", true).put("backgroundCaptureRejected", true)
            .put("stoppedCaptureDiscarded", true).put("realSdkExpiryObserved", true)
            .put("errorSpanSessionsMatchReplay", true).put("otlpRequestsAcknowledged", true)
            .put("errors", JSONArray(listOf(firstError, nextError).map { identity ->
                JSONObject().put("traceId", identity.traceId).put("spanId", identity.spanId)
                    .put("sessionId", identity.sessionId).put("sampled", identity.sampled)
                    .put("triggeredAtEpochMillis", identity.triggeredAtEpochMillis)
            }))
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        File(context.filesDir, "stage3-journey.json").writeText(report.toString(2))
        // UTP may uninstall the app immediately after tests. Its captured logcat retains the same
        // synthetic evidence even when the app-private file is removed during that cleanup.
        Log.i("ReplayJourneyTest", "STAGE3_JOURNEY ${report}")
    }

    private fun errorIdentity(): ReplayDemoError {
        lateinit var identity: ReplayDemoError
        compose.runOnIdle { identity = checkNotNull(ReplayJourney.lastError) }
        assertTrue(identity.traceId.matches(Regex("[0-9a-f]{32}")))
        assertNotEquals("00000000000000000000000000000000", identity.traceId)
        assertTrue(identity.spanId.matches(Regex("[0-9a-f]{16}")))
        assertNotEquals("0000000000000000", identity.spanId)
        assertNotNull("A real SDK span must carry its own session.id", identity.sessionId)
        assertNotNull(identity.triggeredAtEpochMillis)
        assertTrue("The demo trace must be sampled before checking backend persistence", identity.sampled)
        return identity
    }

    private fun awaitTelemetryExports(afterReceipt: Int) {
        compose.waitUntil(20_000) {
            val sent = receipts()
            val acknowledged = (afterReceipt until sent.length()).map { sent.getJSONObject(it) }
                .filter { it.optInt("status") in 200..299 && it.optInt("bytes") > 0 }
                .map { it.optString("path") }
            acknowledged.any { it.endsWith("/v1/traces") } && acknowledged.any { it.endsWith("/v1/logs") }
        }
        // HTTP acknowledgment is a transport check. The verification script separately queries
        // Tempo and Loki for these exact IDs before claiming stored error/trace correlation.
    }

    private fun capture(screen: String): JSONObject {
        val old = frames().size
        compose.onNodeWithTag("replay.capture").performScrollTo()
        compose.waitForIdle()
        compose.onNodeWithTag("replay.capture").performClick()
        compose.waitForIdle()
        var accepted: List<JSONObject> = emptyList()
        compose.waitUntil(15_000) { frames().also { accepted = it }.size > old }
        val frame = accepted.last()
        assertEquals(screen, frame.getString("screen"))
        assertEquals(frame.getString("session"), frame.getString("headerSession"))
        return frame
    }

    private fun frames(): List<JSONObject> {
        val receipts = receipts()
        return buildList {
            for (i in 0 until receipts.length()) {
                val receipt = receipts.getJSONObject(i)
                if (receipt.optInt("status") !in 200..299) continue
                val events = receipt.optJSONArray("events") ?: continue
                for (j in 0 until events.length()) {
                    val event = events.getJSONObject(j)
                    if (event.optInt("type") == 2) add(JSONObject(event.toString())
                        .put("session", receipt.getString("session"))
                        .put("headerSession", receipt.getString("headerSession")))
                }
            }
        }
    }

    private fun receipts(): JSONArray {
        val connection = URL("http://127.0.0.1:18002/_test/receipts").openConnection() as HttpURLConnection
        connection.connectTimeout = 2_000
        connection.readTimeout = 2_000
        return try {
            JSONArray(connection.inputStream.bufferedReader().use { it.readText() })
        } finally { connection.disconnect() }
    }
}

package com.grafana.quickpizza.features.debug

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReplayProbeJsonTest {

    @Test
    fun twoScreensAreVideoCardsInFileOrder() {
        val login = ReplayProbeJson.upsert(
            existingJson = null,
            screenName = "Login",
            width = 1080,
            height = 1920,
            timestamp = 1_710_000_000_000,
        )
        val both = ReplayProbeJson.upsert(
            existingJson = login,
            screenName = "Home",
            width = 1080,
            height = 1920,
            timestamp = 1_710_000_000_100,
        )
        val replaced = ReplayProbeJson.upsert(
            existingJson = both,
            screenName = "Login",
            width = 540,
            height = 960,
            timestamp = 1_710_000_000_200,
        )

        val events = JSONArray(replaced)
        assertEquals(3, events.length())
        assertEquals(2, ReplayProbeJson.frameCount(replaced))
        assertFalse(replaced.contains("data:"))

        val meta = events.getJSONObject(0)
        assertEquals(4, meta.getInt("type"))
        assertEquals(1_710_000_000_000, meta.getLong("timestamp"))
        assertEquals(540, meta.getJSONObject("data").getInt("width"))
        assertEquals(960, meta.getJSONObject("data").getInt("height"))

        val first = events.getJSONObject(1)
        val second = events.getJSONObject(2)
        assertEquals(5, first.getInt("type"))
        assertEquals(5, second.getInt("type"))
        assertEquals("mobile-video", first.getJSONObject("data").getString("kind"))
        assertEquals("0001.mp4", first.getJSONObject("data").getString("file"))
        assertEquals("0002.mp4", second.getJSONObject("data").getString("file"))
        assertEquals(540, first.getJSONObject("data").getInt("width"))
        assertEquals(1080, second.getJSONObject("data").getInt("width"))
        assertEquals(5_000, first.getJSONObject("data").getInt("duration"))
        assertEquals(1, first.getJSONObject("data").getInt("frameRate"))
        assertEquals("h264", first.getJSONObject("data").getString("encoding"))
        assertEquals("mp4", first.getJSONObject("data").getString("container"))
        assertEquals(1_710_000_000_000, first.getLong("timestamp"))
        assertEquals(1_710_000_005_000, second.getLong("timestamp"))
    }

    @Test
    fun homeCapturedFirstStillPlaysAfterLogin() {
        val home = ReplayProbeJson.upsert(
            existingJson = null,
            screenName = "Home",
            width = 1080,
            height = 1920,
            timestamp = 1_710_000_000_000,
        )
        val both = ReplayProbeJson.upsert(
            existingJson = home,
            screenName = "Login",
            width = 1080,
            height = 1920,
            timestamp = 1_710_000_009_000,
        )

        val events = JSONArray(both)
        assertEquals("0001.mp4", events.getJSONObject(1).getJSONObject("data").getString("file"))
        assertEquals("0002.mp4", events.getJSONObject(2).getJSONObject("data").getString("file"))
        assertEquals(
            events.getJSONObject(1).getLong("timestamp") + 5_000,
            events.getJSONObject(2).getLong("timestamp"),
        )
    }

    @Test
    fun payloadHasOneSessionRecordingEventPerCard() {
        val events = ReplayProbeJson.upsert(
            existingJson = null,
            screenName = "Login",
            width = 1080,
            height = 1920,
            timestamp = 1_710_000_000_000,
        )
        val both = ReplayProbeJson.upsert(
            existingJson = events,
            screenName = "Home",
            width = 1080,
            height = 1920,
            timestamp = 1_710_000_000_000,
        )
        val payload = JSONObject(ReplayProbeJson.payload(both))
        assertEquals(ReplayProbeJson.SESSION_ID, payload.getJSONObject("meta").getJSONObject("session").getString("id"))
        val recorded = payload.getJSONArray("events")
        assertEquals(3, recorded.length())
        for (i in 0 until recorded.length()) {
            val event = recorded.getJSONObject(i)
            assertEquals("faro.session_recording.event", event.getString("name"))
            val attributes = event.getJSONObject("attributes")
            assertEquals(ReplayProbeJson.RECORDING_ID, attributes.getString("recording_id"))
            assertEquals("0", attributes.getString("gen"))
            assertEquals(i.toString(), attributes.getString("seq"))
            val card = JSONObject(attributes.getString("event"))
            assertEquals(JSONArray(both).getJSONObject(i).getInt("type"), card.getInt("type"))
            assertFalse(attributes.getString("event").contains("ftyp"))
        }
        assertTrue(payload.toString().length < ReplayProbeJson.MAX_CLIP_BYTES)
    }
}

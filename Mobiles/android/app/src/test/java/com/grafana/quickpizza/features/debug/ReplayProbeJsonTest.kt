package com.grafana.quickpizza.features.debug

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ReplayProbeJsonTest {

    @Test
    fun twoScreensReplaceByNameAndStayOrdered() {
        val login = ReplayProbeJson.upsert(
            existingJson = null,
            screenName = "Login",
            width = 1080,
            height = 1920,
            dataUri = "data:image/webp;base64,LOGIN",
            timestamp = 1_710_000_000_000,
        )
        val both = ReplayProbeJson.upsert(
            existingJson = login,
            screenName = "Home",
            width = 1080,
            height = 1920,
            dataUri = "data:image/webp;base64,HOME",
            timestamp = 1_710_000_000_100,
        )
        val replaced = ReplayProbeJson.upsert(
            existingJson = both,
            screenName = "Login",
            width = 1080,
            height = 1920,
            dataUri = "data:image/webp;base64,LOGIN2",
            timestamp = 1_710_000_000_200,
        )

        val events = JSONArray(replaced)
        assertEquals(3, events.length())
        assertEquals(2, ReplayProbeJson.frameCount(replaced))
        assertEquals(4, events.getJSONObject(0).getInt("type"))
        assertTrue(events.getJSONObject(0).getLong("timestamp") > 0)
        assertTrue(
            events.getJSONObject(0).getLong("timestamp") <
                events.getJSONObject(1).getLong("timestamp"),
        )

        val firstSrc = imgSrc(events.getJSONObject(1))
        val secondSrc = imgSrc(events.getJSONObject(2))
        assertEquals("data:image/webp;base64,HOME", firstSrc)
        assertEquals("data:image/webp;base64,LOGIN2", secondSrc)
        assertNotEquals(firstSrc, secondSrc)
        assertEquals(0, events.getJSONObject(1).getJSONObject("data").getJSONObject("initialOffset").getInt("left"))
    }

    private fun imgSrc(snapshot: JSONObject): String {
        val html = snapshot
            .getJSONObject("data")
            .getJSONObject("node")
            .getJSONArray("childNodes")
            .getJSONObject(1)
        val body = html.getJSONArray("childNodes").getJSONObject(1)
        return body.getJSONArray("childNodes").getJSONObject(0).getJSONObject("attributes").getString("src")
    }
}

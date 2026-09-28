package com.grafana.quickpizza.features.debug

import java.time.Instant
import org.json.JSONArray
import org.json.JSONObject

/**
 * Player-contract probe file: one Meta plus one mobile-video card per captured screen.
 * The array is what the Session Replay player reads. It does not contain the mp4.
 */
object ReplayProbeJson {
    const val FILE_NAME = "replay-probe.json"
    const val PAYLOAD_FILE_NAME = "replay-probe-payload.json"
    const val CLIPS_DIR = "clips"
    const val DURATION_MS = 5_000L
    const val FRAME_RATE = 1
    const val MAX_CLIP_BYTES = 1 * 1024 * 1024
    const val RECORDING_ID = "probe"
    const val SESSION_ID = "replay-probe-session"

    fun fileFor(screenName: String): String = when (screenName) {
        "Login" -> "0001.mp4"
        "Home" -> "0002.mp4"
        else -> throw IllegalArgumentException("Replay probe only captures Login and Home")
    }

    fun upsert(
        existingJson: String?,
        screenName: String,
        width: Int,
        height: Int,
        timestamp: Long,
    ): String {
        val cards = linkedMapOf<String, ClipCard>()
        var base = timestamp
        if (!existingJson.isNullOrBlank()) {
            val parsed = try {
                JSONArray(existingJson)
            } catch (_: Exception) {
                JSONArray()
            }
            for (i in 0 until parsed.length()) {
                val event = parsed.optJSONObject(i) ?: continue
                when (event.optInt("type")) {
                    META -> {
                        val existingBase = event.optLong("timestamp")
                        if (existingBase > 0L) base = existingBase
                    }
                    CUSTOM -> {
                        val data = event.optJSONObject("data") ?: continue
                        if (data.optString("kind") != KIND) continue
                        val file = data.optString("file")
                        if (file.isEmpty()) continue
                        cards[file] = ClipCard(
                            file = file,
                            width = data.optInt("width", width),
                            height = data.optInt("height", height),
                        )
                    }
                }
            }
        }
        val file = fileFor(screenName)
        cards[file] = ClipCard(file = file, width = width, height = height)

        val ordered = cards.values.sortedBy { it.file }
        val metaSize = ordered.first()
        val out = JSONArray()
        out.put(meta(metaSize.width, metaSize.height, base))
        ordered.forEachIndexed { index, card ->
            out.put(videoCard(card, base + index * DURATION_MS))
        }
        return out.toString()
    }

    fun payload(eventsJson: String): String {
        val events = JSONArray(eventsJson)
        val outEvents = JSONArray()
        for (i in 0 until events.length()) {
            val card = events.getJSONObject(i)
            val timestamp = card.getLong("timestamp")
            outEvents.put(
                JSONObject()
                    .put("name", EVENT_NAME)
                    .put("timestamp", Instant.ofEpochMilli(timestamp).toString())
                    .put(
                        "attributes",
                        JSONObject()
                            .put("recording_id", RECORDING_ID)
                            .put("gen", "0")
                            .put("seq", i.toString())
                            .put("event", card.toString()),
                    ),
            )
        }
        return JSONObject()
            .put(
                "meta",
                JSONObject().put("session", JSONObject().put("id", SESSION_ID)),
            )
            .put("events", outEvents)
            .toString()
    }

    fun frameCount(json: String): Int {
        val parsed = JSONArray(json)
        var count = 0
        for (i in 0 until parsed.length()) {
            val event = parsed.optJSONObject(i) ?: continue
            if (event.optInt("type") == CUSTOM && event.optJSONObject("data")?.optString("kind") == KIND) {
                count += 1
            }
        }
        return count
    }

    private fun meta(width: Int, height: Int, timestamp: Long): JSONObject {
        return JSONObject()
            .put("type", META)
            .put("timestamp", timestamp)
            .put(
                "data",
                JSONObject()
                    .put("width", width)
                    .put("height", height),
            )
    }

    private fun videoCard(card: ClipCard, timestamp: Long): JSONObject {
        return JSONObject()
            .put("type", CUSTOM)
            .put("timestamp", timestamp)
            .put(
                "data",
                JSONObject()
                    .put("kind", KIND)
                    .put("file", card.file)
                    .put("width", card.width)
                    .put("height", card.height)
                    .put("duration", DURATION_MS)
                    .put("frameRate", FRAME_RATE)
                    .put("encoding", "h264")
                    .put("container", "mp4"),
            )
    }

    private data class ClipCard(val file: String, val width: Int, val height: Int)

    private const val META = 4
    private const val CUSTOM = 5
    private const val KIND = "mobile-video"
    private const val EVENT_NAME = "faro.session_recording.event"
}

package com.grafana.quickpizza.features.debug

import org.json.JSONArray
import org.json.JSONObject

/**
 * Player-contract probe file: one Meta plus one FullSnapshot per captured screen.
 * The array is what `@grafana/rrweb-replay` consumes. It is not a Faro envelope.
 */
object ReplayProbeJson {
    const val FILE_NAME = "replay-probe.json"

    fun upsert(
        existingJson: String?,
        screenName: String,
        width: Int,
        height: Int,
        dataUri: String,
        timestamp: Long,
    ): String {
        val kept = JSONArray()
        if (!existingJson.isNullOrBlank()) {
            val parsed = try {
                JSONArray(existingJson)
            } catch (_: Exception) {
                JSONArray()
            }
            for (i in 0 until parsed.length()) {
                val event = parsed.optJSONObject(i) ?: continue
                if (event.optInt("type") != FULL_SNAPSHOT) continue
                if (snapshotAlt(event) == screenName) continue
                kept.put(event)
            }
        }
        kept.put(fullSnapshot(screenName, width, height, dataUri, timestamp))

        val ordered = (0 until kept.length())
            .map { kept.getJSONObject(it) }
            .sortedBy { it.getLong("timestamp") }
            .map { JSONObject(it.toString()) }
            .toMutableList()

        var cursor = ordered.first().getLong("timestamp")
        for (index in ordered.indices) {
            val event = ordered[index]
            val ts = event.getLong("timestamp")
            val unique = if (ts <= cursor && index > 0) cursor + 1 else ts
            event.put("timestamp", unique)
            cursor = unique
        }

        var metaTimestamp = ordered.first().getLong("timestamp") - 1
        if (metaTimestamp <= 0L) {
            metaTimestamp = 1L
            if (ordered.first().getLong("timestamp") <= metaTimestamp) {
                var next = metaTimestamp + 1
                for (event in ordered) {
                    event.put("timestamp", next)
                    next += 1
                }
            }
        }

        val (frameWidth, frameHeight) = snapshotSize(ordered.first()) ?: (width to height)
        val href = snapshotAlt(ordered.first()) ?: screenName
        val out = JSONArray()
        out.put(meta(href, frameWidth, frameHeight, metaTimestamp))
        ordered.forEach { out.put(it) }
        return out.toString()
    }

    fun frameCount(json: String): Int {
        val parsed = JSONArray(json)
        var count = 0
        for (i in 0 until parsed.length()) {
            if (parsed.optJSONObject(i)?.optInt("type") == FULL_SNAPSHOT) count += 1
        }
        return count
    }

    private fun meta(href: String, width: Int, height: Int, timestamp: Long): JSONObject {
        return JSONObject()
            .put("type", META)
            .put("timestamp", timestamp)
            .put(
                "data",
                JSONObject()
                    .put("href", href)
                    .put("width", width)
                    .put("height", height),
            )
    }

    private fun fullSnapshot(
        screenName: String,
        width: Int,
        height: Int,
        dataUri: String,
        timestamp: Long,
    ): JSONObject {
        val img = element(
            tag = "img",
            id = 6,
            attributes = JSONObject()
                .put("alt", screenName)
                .put("src", dataUri)
                .put("width", width.toString())
                .put("height", height.toString()),
            children = JSONArray(),
        )
        val body = element(
            tag = "body",
            id = 5,
            attributes = JSONObject().put("style", "margin:0;background:#111;"),
            children = JSONArray().put(img),
        )
        val head = element(tag = "head", id = 4, attributes = JSONObject(), children = JSONArray())
        val html = element(
            tag = "html",
            id = 3,
            attributes = JSONObject(),
            children = JSONArray().put(head).put(body),
        )
        val doctype = JSONObject()
            .put("type", 1)
            .put("name", "html")
            .put("publicId", "")
            .put("systemId", "")
            .put("id", 2)
            .put("childNodes", JSONArray())
        val document = JSONObject()
            .put("type", 0)
            .put("id", 1)
            .put("childNodes", JSONArray().put(doctype).put(html))
        return JSONObject()
            .put("type", FULL_SNAPSHOT)
            .put("timestamp", timestamp)
            .put(
                "data",
                JSONObject()
                    .put("node", document)
                    .put(
                        "initialOffset",
                        JSONObject().put("left", 0).put("top", 0),
                    ),
            )
    }

    private fun element(tag: String, id: Int, attributes: JSONObject, children: JSONArray): JSONObject {
        return JSONObject()
            .put("type", 2)
            .put("tagName", tag)
            .put("id", id)
            .put("attributes", attributes)
            .put("childNodes", children)
    }

    private fun snapshotAlt(event: JSONObject): String? {
        val node = event.optJSONObject("data")?.optJSONObject("node") ?: return null
        return findAlt(node)
    }

    private fun findAlt(node: JSONObject): String? {
        val alt = node.optJSONObject("attributes")?.optString("alt", "")?.takeIf { it.isNotEmpty() }
        if (alt != null) return alt
        val children = node.optJSONArray("childNodes") ?: return null
        for (i in 0 until children.length()) {
            val child = children.optJSONObject(i) ?: continue
            val found = findAlt(child)
            if (found != null) return found
        }
        return null
    }

    private fun snapshotSize(event: JSONObject): Pair<Int, Int>? {
        val node = event.optJSONObject("data")?.optJSONObject("node") ?: return null
        return findSize(node)
    }

    private fun findSize(node: JSONObject): Pair<Int, Int>? {
        if (node.optString("tagName") == "img") {
            val attrs = node.optJSONObject("attributes") ?: return null
            val width = attrs.optString("width").toIntOrNull()
            val height = attrs.optString("height").toIntOrNull()
            if (width != null && height != null) return width to height
        }
        val children = node.optJSONArray("childNodes") ?: return null
        for (i in 0 until children.length()) {
            val child = children.optJSONObject(i) ?: continue
            val found = findSize(child)
            if (found != null) return found
        }
        return null
    }

    private const val FULL_SNAPSHOT = 2
    private const val META = 4
}

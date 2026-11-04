package com.grafana.quickpizza.features.replay

import android.graphics.Bitmap
import android.graphics.Color
import android.media.MediaMetadataRetriever
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.LayoutInfo
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.espresso.Espresso.closeSoftKeyboard
import androidx.test.platform.app.InstrumentationRegistry
import com.grafana.quickpizza.MainActivity
import com.grafana.faro.replay.FaroReplay
import com.grafana.faro.replay.FaroReplayNavigationHost
import com.grafana.faro.replay.FaroReplayProcessHost
import com.grafana.faro.replay.FaroReplaySessionHost
import com.grafana.faro.replay.MaskOptions
import java.io.ByteArrayInputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import java.util.IdentityHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import java.util.zip.GZIPInputStream
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Opt-in test of the installed library, real app UI and local collector. No capture API calls. */
class InstalledReplayJourneyTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val steps = JSONArray()
    private lateinit var evidence: File
    private var receiptBaseline = 0
    private val receiver = "http://10.0.2.2:18002"
    private val layoutDiagnosticsOnly =
        InstrumentationRegistry.getArguments().getString("replayLayoutDiagnosticsOnly") == "true"

    @Test
    fun installedLibraryRecordsNavigationInputsAndAnError() {
        assumeTrue(
            "Requires a disposable emulator, local collector and synthetic demo configuration",
            InstrumentationRegistry.getArguments().getString("installedReplayJourney") == "true",
        )
        evidence = File(instrumentation.targetContext.filesDir, "installed-replay/${UUID.randomUUID()}")
        check(evidence.mkdirs())
        val report = JSONObject()
            .put("kind", "installed library through real QuickPizza UI and local collector")
            .put("manualCaptureCalls", 0)
            .put("diagnosticOnly", layoutDiagnosticsOnly)
            .put("startedAtMillis", System.currentTimeMillis())
            .put("steps", steps)
        try {
            receiptBaseline = receipts().length()
            compose.onNodeWithText("QuickPizza has your back!").assertExists()
            settledScreenWithUploadedFrame("home", "QuickPizza has your back!")

            compose.onNodeWithContentDescription("Profile").performClick()
            compose.onNodeWithText("Username").assertExists()
            settledScreenWithUploadedFrame("login-empty", "Welcome to QuickPizza")

            // Deliberately invalid synthetic credentials produce the app's real auth error.
            compose.onNodeWithText("Username").performTextInput("replay-demo@example.invalid")
            compose.onNodeWithText("Password").performTextInput("synthetic-demo-password")
            closeSoftKeyboard()
            compose.waitForIdle()
            val fields = listOf("Username", "Password").map {
                compose.onNodeWithText(it).assertIsDisplayed().fetchSemanticsNode().boundsInRoot
            }
            settledScreenshot("login-populated", fields)

            val errorTriggeredAt = System.currentTimeMillis()
            compose.onNodeWithText("Sign In").performScrollTo().performClick()
            compose.waitUntil(10_000) {
                compose.onAllNodesWithText("Login failed: HTTP 401").fetchSemanticsNodes().isNotEmpty()
            }
            compose.onNodeWithText("Login failed: HTTP 401").performScrollTo().assertIsDisplayed()
            compose.waitForIdle()
            val errorFields = listOf("Username", "Password").map {
                compose.onNodeWithText(it).assertIsDisplayed().fetchSemanticsNode().boundsInRoot
            }
            val errorBounds = compose.onNodeWithText("Login failed: HTTP 401")
                .assertIsDisplayed().fetchSemanticsNode().boundsInRoot
            val errorVisibleAt = System.currentTimeMillis()
            val errorScreenshot = settledScreenshot("login-error", errorFields)
            if (layoutDiagnosticsOnly) {
                report.put("layoutDiagnostics", replayDiagnostics()).put("validationCompleted", false)
                return
            }
            // Typed inputs can have identical masked pixels. The real visible error supplies
            // a changed public region, so this checks a new frame rather than a held empty form.
            assertInputsMaskedInUploadedVideo(errorVisibleAt, errorFields, errorBounds, errorScreenshot)
            report.put("populatedInputMaskChecked", true)
            report.put("error", JSONObject().put("message", "Login failed")
                .put("traceName", "auth.login").put("triggeredAtMillis", errorTriggeredAt)
                .put("visibleAtMillis", errorVisibleAt))

            // These are the public synthetic credentials displayed by the demo itself.
            compose.onNodeWithText("Username").performTextReplacement("default")
            compose.onNodeWithText("Password").performTextReplacement("12345678")
            closeSoftKeyboard()
            compose.waitForIdle()
            settledScreenshot("login-demo-account")
            compose.onNodeWithText("Sign In").performScrollTo().performClick()
            compose.waitUntil(10_000) {
                compose.onAllNodesWithText("QuickPizza has your back!").fetchSemanticsNodes().isNotEmpty()
            }
            settledScreenshot("home-signed-in")

            compose.onNodeWithContentDescription("Profile").performClick()
            compose.waitUntil(10_000) {
                compose.onAllNodesWithText("Your Ratings").fetchSemanticsNodes().isNotEmpty()
            }
            compose.onNodeWithText("Your Ratings").assertExists()
            settledScreenWithUploadedFrame("profile", "Your Ratings")
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithContentDescription("About", useUnmergedTree = true).performTouchInput { click() }
            settledScreenWithUploadedFrame("about", "About QuickPizza")

            val clips = clips()
            assertTrue("Navigation and visible state changes must upload several automatic clips", clips.size >= 4)
            val sessions = clips.map { it.getString("session") }.toSet()
            assertEquals("The journey must retain one SDK session", 1, sessions.size)
            val session = sessions.single()
            report.put("sessionId", session).put("clipCount", clips.size)
                .put("clipReceipts", JSONArray(clips))
            report.put("exportedTelemetry", awaitErrorTelemetry(session))
            report.put("passed", true)
        } catch (failure: Throwable) {
            report.put("passed", false).put("failure", failure.toString())
            report.put("replayStateAtFailure", replayDiagnostics())
            throw failure
        } finally {
            report.put("finishedAtMillis", System.currentTimeMillis())
            File(evidence, "journey.json").writeText(report.toString(2))
            File(instrumentation.targetContext.filesDir, "installed-replay-latest.json").writeText(
                JSONObject().put("directory", evidence.name).put("report", report).toString(2),
            )
        }
    }

    /** Failure-only inspection. Never calls a capture, lifecycle callback or the SDK session getter. */
    private fun replayDiagnostics(): JSONObject = runCatching {
        val result = JSONObject()
        instrumentation.runOnMainSync {
            val service = compose.activity.otelService
            val session = field(service, "replaySessionHost") as? FaroReplaySessionHost
            val process = field(service, "processHost") as? FaroReplayProcessHost
            val navigation = field(service, "replayNavigationHost") as? FaroReplayNavigationHost
            result.put("sdkInitialized", service.openTelemetryRum != null)
                .put("installed", field(service, "replayInstallation") != null)
                .put("sessionSnapshot", session?.currentSessionSnapshot()?.toString())
                .put("foreground", process?.isForeground())
                .put("eligibleWindow", process?.hasEligibleWindow())
                .put("windowPresent", process?.currentWindow() != null)
                .put("screen", navigation?.currentScreenId())
            val visited = IdentityHashMap<Any, Boolean>()
            val installation = field(FaroReplay, "active")
            result.put("state", diagnosticValue(installation, 0, visited))
            process?.currentWindow()?.let { window ->
                result.put("nativeViewTree", nativeViewTree(window.decorView))
                result.put("sensitiveLayoutPaths", sensitiveLayoutPaths(window.decorView))
                val versions = JSONObject()
                for (name in listOf("androidx.compose.ui_ui", "androidx.compose.ui_ui-text",
                    "androidx.compose.foundation_foundation", "androidx.compose.foundation_foundation-layout")) {
                    versions.put(name, javaClass.classLoader?.getResourceAsStream("META-INF/$name.version")
                        ?.bufferedReader()?.use { it.readText().trim() } ?: "missing")
                }
                result.put("runtimeVersions", versions)
                result.put("maskGeometry", runCatching {
                    val source = findDiagnosticObject(installation,
                        "com.grafana.faro.replay.internal.ComposeMaskSource", IdentityHashMap())
                    if (source == null) {
                        JSONObject().put("sourcePresent", false)
                    } else {
                        val snapshot = source.javaClass.declaredMethods.single { it.name == "snapshot" }
                            .apply { isAccessible = true }
                            .invoke(source, window, navigation?.currentScreenId().orEmpty(),
                                MaskOptions(maskAllText = false, maskAllInputs = true, blockAllMedia = false))
                        JSONObject().put("sourcePresent", true).put("available", snapshot != null).also { geometry ->
                            if (snapshot != null) {
                                geometry.put("width", field(snapshot, "widthPx"))
                                    .put("height", field(snapshot, "heightPx"))
                                    .put("rectangles", JSONArray((field(snapshot, "rectangles") as List<*>).map { rect ->
                                        JSONObject().also { item ->
                                            for (edge in listOf("left", "top", "right", "bottom")) {
                                                item.put(edge, field(checkNotNull(rect), edge))
                                            }
                                        }
                                    }))
                            }
                        }
                    }
                }.getOrElse { JSONObject().put("inspectionFailure", it.toString()) })
            }
        }
        result
    }.getOrElse { JSONObject().put("inspectionFailure", it.toString()) }

    private fun field(owner: Any, name: String): Any? =
        owner.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(owner)

    private fun nativeViewTree(root: View): JSONArray {
        val nodes = JSONArray()
        fun visit(view: View, depth: Int) {
            if (depth > 12 || nodes.length() >= 128) return
            nodes.put(JSONObject().put("depth", depth).put("class", view.javaClass.name)
                .put("width", view.width).put("height", view.height).put("visibility", view.visibility)
                .put("alpha", view.alpha).put("attached", view.isAttachedToWindow)
                .put("layoutRequested", view.isLayoutRequested).put("windowFocus", view.hasWindowFocus())
                .put("children", (view as? ViewGroup)?.childCount ?: 0))
            if (view is ViewGroup) for (index in 0 until view.childCount) visit(view.getChildAt(index), depth + 1)
        }
        visit(root, 0)
        return nodes
    }

    @android.annotation.SuppressLint("VisibleForTests")
    private fun sensitiveLayoutPaths(root: View): JSONArray {
        val paths = JSONArray()
        var nodeCount = 0
        fun semantics(node: SemanticsNode) {
            if (++nodeCount > 1_000) return
            val config = node.config
            val password = config.contains(SemanticsProperties.Password)
            val input = config.contains(SemanticsProperties.EditableText) || config.contains(SemanticsActions.SetText)
            val excluded = config.any { it.key.name == "GrafanaNoCapture" } || config.isClearingSemantics
            if (password || input || excluded) {
                val ancestors = JSONArray()
                var layout: LayoutInfo? = node.layoutInfo
                val visited = IdentityHashMap<LayoutInfo, Boolean>()
                while (layout != null && visited.size < 64 && visited.put(layout, true) == null) {
                    val current = layout
                    val modifiers = JSONArray()
                    for (info in current.getModifierInfo()) {
                        val modifier = info.modifier
                        val item = JSONObject().put("class", modifier.javaClass.name)
                            .put("bounds", info.coordinates.boundsInWindow().toString())
                        // Read only shape class and numeric layer settings, never inspector values or painters.
                        for (name in listOf("clip", "alpha", "scaleX", "scaleY", "translationX", "translationY",
                            "rotationX", "rotationY", "rotationZ", "shadowElevation")) {
                            runCatching { field(modifier, name) }.getOrNull()?.let { item.put(name, it) }
                        }
                        runCatching { field(modifier, "shape") }.getOrNull()?.let { item.put("shapeClass", it.javaClass.name) }
                        for (name in listOf("measure", "block", "graphicsLayerBlock", "isEnabled")) {
                            runCatching { field(modifier, name) }.getOrNull()?.let {
                                item.put("${name}Class", it.javaClass.name)
                            }
                        }
                        runCatching { field(modifier, "transition") }.getOrNull()?.let { transition ->
                            val state = JSONObject().put("class", transition.javaClass.name)
                            for (getter in listOf("getCurrentState", "getTargetState", "isRunning")) {
                                state.put(getter, runCatching {
                                    val value = transition.javaClass.getMethod(getter).invoke(transition)
                                    diagnosticScalar(value)
                                }.getOrElse { "unavailable:${it.javaClass.simpleName}" })
                            }
                            item.put("transition", state)
                        }
                        runCatching { field(modifier, "overscrollEffect") }.getOrNull()?.let { effect ->
                            val state = JSONObject().put("class", effect.javaClass.name)
                            state.put("isInProgress", runCatching {
                                effect.javaClass.getMethod("isInProgress").apply { isAccessible = true }.invoke(effect)
                            }.getOrElse { "unavailable:${it.javaClass.simpleName}" })
                            item.put("overscroll", state)
                        }
                        item.put("extraClass", runCatching {
                            info.javaClass.getMethod("getExtra").invoke(info)?.javaClass?.name
                        }.getOrNull() ?: "none")
                        item.put("coordinates", coordinateLayerState(info.coordinates))
                        modifiers.put(item)
                    }
                    ancestors.put(JSONObject().put("class", current.javaClass.name)
                        .put("placed", current.isPlaced).put("attached", current.isAttached)
                        .put("deactivated", current.isDeactivated).put("modifiers", modifiers))
                    layout = current.parentInfo
                }
                paths.put(JSONObject().put("password", password).put("input", input)
                    .put("excluded", excluded).put("bounds", node.boundsInWindow.toString())
                    .put("ancestors", ancestors).put("descendants", descendantModifiers(node.layoutInfo)))
            }
            node.children.forEach(::semantics)
        }
        fun views(view: View) {
            if (view is ViewRootForTest) semantics(view.semanticsOwner.unmergedRootSemanticsNode)
            if (view is ViewGroup) for (index in 0 until view.childCount) views(view.getChildAt(index))
        }
        views(root)
        return paths
    }

    private fun descendantModifiers(root: LayoutInfo): JSONArray {
        val result = JSONArray()
        val visited = IdentityHashMap<LayoutInfo, Boolean>()
        fun visit(layout: LayoutInfo, depth: Int) {
            if (depth > 32 || visited.size >= 256 || visited.put(layout, true) != null) return
            val modifiers = JSONArray()
            if (layout.isAttached && layout.isPlaced) {
                for (info in layout.getModifierInfo()) {
                    val modifier = info.modifier
                    val item = JSONObject().put("class", modifier.javaClass.name)
                        .put("bounds", info.coordinates.boundsInWindow().toString())
                    for (name in listOf("clip", "alpha", "scaleX", "scaleY", "translationX", "translationY",
                        "rotationX", "rotationY", "rotationZ", "shadowElevation")) {
                        runCatching { field(modifier, name) }.getOrNull()?.let { item.put(name, diagnosticScalar(it)) }
                    }
                    runCatching { field(modifier, "shape") }.getOrNull()?.let { item.put("shapeClass", it.javaClass.name) }
                    modifiers.put(item)
                }
            }
            result.put(JSONObject().put("depth", depth).put("class", layout.javaClass.name)
                .put("placed", layout.isPlaced).put("attached", layout.isAttached).put("modifiers", modifiers))
            val children = layout.javaClass.getMethod("getChildren\$ui_release")
                .apply { isAccessible = true }.invoke(layout) as List<*>
            children.filterIsInstance<LayoutInfo>().forEach { visit(it, depth + 1) }
        }
        visit(root, 0)
        return result
    }

    private fun diagnosticScalar(value: Any?): Any = when (value) {
        null -> JSONObject.NULL
        is Boolean, is Number -> value
        is Enum<*> -> value.name
        else -> JSONObject().put("class", value.javaClass.name)
    }

    private fun coordinateLayerState(coordinates: Any): JSONObject {
        fun inheritedField(owner: Any, name: String): Any? {
            var type: Class<*>? = owner.javaClass
            while (type != null) {
                val member = type.declaredFields.firstOrNull { it.name == name }
                if (member != null) return member.apply { isAccessible = true }.get(owner)
                type = type.superclass
            }
            return null
        }
        val result = JSONObject().put("class", coordinates.javaClass.name)
        for (name in listOf("isClipping", "lastLayerAlpha", "lastLayerDrawingWasSkipped")) {
            runCatching { inheritedField(coordinates, name) }.getOrNull()?.let {
                result.put(name, diagnosticScalar(it))
            }
        }
        for (name in listOf("layer", "layerBlock", "explicitLayer")) {
            runCatching { inheritedField(coordinates, name) }.getOrNull()?.let {
                result.put("${name}Class", it.javaClass.name)
            }
        }
        runCatching { inheritedField(coordinates, "layerPositionalProperties") }.getOrNull()?.let { properties ->
            val values = JSONObject().put("class", properties.javaClass.name)
            for (name in listOf("scaleX", "scaleY", "translationX", "translationY", "rotationX",
                "rotationY", "rotationZ", "cameraDistance", "transformOrigin")) {
                runCatching { inheritedField(properties, name) }.getOrNull()?.let { values.put(name, diagnosticScalar(it)) }
            }
            result.put("layerPositionalProperties", values)
        }
        return result
    }

    private fun findDiagnosticObject(value: Any?, type: String, visited: IdentityHashMap<Any, Boolean>): Any? {
        if (value == null || visited.size >= 32 || visited.put(value, true) != null) return null
        if (value.javaClass.name == type) return value
        if (value is AtomicReference<*>) return findDiagnosticObject(value.get(), type, visited)
        if (!value.javaClass.name.startsWith("com.grafana.faro.replay.")) return null
        for (member in value.javaClass.declaredFields) {
            if (member.name !in setOf("closeAction", "\$controller", "driver", "masks") && !member.name.startsWith("f\$")) continue
            member.isAccessible = true
            findDiagnosticObject(member.get(value), type, visited)?.let { return it }
        }
        return null
    }

    private fun diagnosticValue(value: Any?, depth: Int, visited: IdentityHashMap<Any, Boolean>): Any {
        if (value == null) return JSONObject.NULL
        if (value is Boolean || value is Number || value is String) return value
        if (value is AtomicBoolean) return value.get()
        if (value is AtomicReference<*>) return diagnosticValue(value.get(), depth, visited)
        if (value is Collection<*>) return JSONObject().put("count", value.size)
        val type = value.javaClass.name
        if (depth >= 9 || visited.put(value, true) != null || !type.startsWith("com.grafana.faro.replay.")) {
            return JSONObject().put("class", type)
        }
        val result = JSONObject().put("class", type)
        // Only recorder state and captured controller links; never config, headers, images or UI contents.
        val allowed = setOf(
            "closeAction", "driver", "coordinator", "changes", "sink", "segmenter", "uploader",
            "active", "installed", "closed", "cleanedUp", "foreground", "screen", "window", "observer",
            "attempt", "epoch", "lifecycleVersion", "resolving", "admitting", "snapshot", "scope", "pending",
            "timerGeneration", "deadlineCancellation", "dispatchFailed", "key", "sessionId", "sdkEpoch",
            "recordingId", "deadline", "expired", "isRumSampled", "invalidationEpoch", "screenName", "permit",
            "generation", "sequence", "inFlight", "dirty", "scheduled", "lastAccepted", "lastUploaded",
        )
        value.javaClass.declaredFields.filter { member ->
            !java.lang.reflect.Modifier.isStatic(member.modifiers) &&
                (member.name in allowed || member.name == "\$controller" || member.name.startsWith("f\$"))
        }.forEach { member ->
            result.put(member.name, runCatching {
                member.isAccessible = true
                diagnosticValue(member.get(value), depth + 1, visited)
            }.getOrElse { JSONObject().put("inspectionFailure", it.javaClass.simpleName) })
        }
        return result
    }

    /** Require each route's visible public content in an accepted MP4, not only a raw screenshot. */
    private fun settledScreenWithUploadedFrame(name: String, label: String): JSONObject {
        compose.onNodeWithText(label).assertIsDisplayed()
        val observedAt = System.currentTimeMillis()
        val publicBounds = compose.onNodeWithText(label).fetchSemanticsNode().boundsInRoot
        val screenshot = settledScreenshot(name)
        if (layoutDiagnosticsOnly) return screenshot
        val expected = android.graphics.BitmapFactory.decodeFile(File(evidence, "$name.png").path)
        try {
            val deadline = SystemClock.elapsedRealtime() + 12_000
            val checked = mutableSetOf<Int>()
            while (SystemClock.elapsedRealtime() < deadline) {
                for (clip in clips()) {
                    val index = clip.getInt("index")
                    val event = clip.getJSONArray("events").getJSONObject(0)
                    val start = event.getLong("timestamp")
                    if (index in checked || start + 5_000 < observedAt - 1_000) continue
                    checked.add(index)
                    val file = File(evidence, "$name-clip-$index.mp4")
                    file.writeBytes(get(clip.getString("clipUrl").replace("127.0.0.1", "10.0.2.2")))
                    val retriever = MediaMetadataRetriever()
                    try {
                        retriever.setDataSource(file.path)
                        for (slot in 0L..4L) {
                            if (start + slot * 1_000 < observedAt - 1_000) continue
                            val frame = retriever.getFrameAtTime(slot * 1_000_000, MediaMetadataRetriever.OPTION_CLOSEST) ?: continue
                            try {
                                // Compare only the asserted, stable public label. Inputs and system
                                // UI are deliberately excluded, and codec loss is allowed explicitly.
                                var difference = 0L
                                var channels = 0
                                var expectedInk = 0
                                var inkDifference = 0L
                                for (y in publicBounds.top.toInt() until publicBounds.bottom.toInt() step 2) {
                                    for (x in publicBounds.left.toInt() until publicBounds.right.toInt() step 2) {
                                        val reference = expected.getPixel(x.coerceIn(0, expected.width - 1), y.coerceIn(0, expected.height - 1))
                                        val actual = frame.getPixel(
                                            (x.toLong() * frame.width / expected.width).toInt().coerceIn(0, frame.width - 1),
                                            (y.toLong() * frame.height / expected.height).toInt().coerceIn(0, frame.height - 1),
                                        )
                                        val referenceChannels = intArrayOf(Color.red(reference), Color.green(reference), Color.blue(reference))
                                        val actualChannels = intArrayOf(Color.red(actual), Color.green(actual), Color.blue(actual))
                                        for (channel in 0..2) difference += kotlin.math.abs(referenceChannels[channel] - actualChannels[channel])
                                        channels += 3
                                        if (referenceChannels.minOrNull()!! < 120) {
                                            expectedInk++
                                            for (channel in 0..2) inkDifference += kotlin.math.abs(referenceChannels[channel] - actualChannels[channel])
                                        }
                                    }
                                }
                                val meanDifference = if (channels == 0) Double.POSITIVE_INFINITY else difference.toDouble() / channels
                                val meanInkDifference = if (expectedInk == 0) Double.POSITIVE_INFINITY else inkDifference.toDouble() / (expectedInk * 3)
                                if (expectedInk > 20 && meanDifference < 18.0 && meanInkDifference < 32.0) {
                                    File(evidence, "verified-$name.png").outputStream().use {
                                        assertTrue(frame.compress(Bitmap.CompressFormat.PNG, 100, it))
                                    }
                                    screenshot.put("verifiedPublicLabel", label).put("verifiedClipIndex", index)
                                        .put("verifiedSlot", slot).put("verifiedFrameAtMillis", start + slot * 1_000)
                                        .put("labelMeanAbsoluteDifference", meanDifference).put("labelInkMeanAbsoluteDifference", meanInkDifference)
                                    return screenshot
                                }
                            } finally {
                                frame.recycle()
                            }
                        }
                    } finally {
                        retriever.release()
                    }
                }
                SystemClock.sleep(250)
            }
            fail("No accepted MP4 displayed the asserted public content for $name ($label)")
        } finally {
            expected.recycle()
        }
        return screenshot
    }

    private fun settledScreenshot(name: String, fields: List<Rect> = emptyList()): JSONObject {
        compose.waitForIdle()
        // Real elapsed time: allow the installed debounce and five-second segment flush to run.
        SystemClock.sleep(if (layoutDiagnosticsOnly) 1_000 else 6_000)
        val screenshot = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        try {
            File(evidence, "$name.png").outputStream().use {
                assertTrue(screenshot.compress(Bitmap.CompressFormat.PNG, 100, it))
            }
            return JSONObject().put("name", name).put("atMillis", System.currentTimeMillis())
                .put("screenshot", "$name.png").put("width", screenshot.width).put("height", screenshot.height)
                .put("inputBounds", JSONArray(fields.map { rect ->
                    JSONObject().put("left", rect.left).put("top", rect.top)
                        .put("right", rect.right).put("bottom", rect.bottom)
                })).also(steps::put)
        } finally {
            screenshot.recycle()
        }
    }

    private fun assertInputsMaskedInUploadedVideo(afterMillis: Long, fields: List<Rect>, errorBounds: Rect, screenshot: JSONObject) {
        val deadline = SystemClock.elapsedRealtime() + 10_000
        val checked = mutableSetOf<Int>()
        while (SystemClock.elapsedRealtime() < deadline) {
            for (clip in clips()) {
                val index = clip.getInt("index")
                val event = clip.getJSONArray("events").getJSONObject(0)
                val start = event.getLong("timestamp")
                if (index in checked || start < afterMillis - 5_000 || start > screenshot.getLong("atMillis")) continue
                checked.add(index)
                val file = File(evidence, "mask-clip-$index.mp4")
                file.writeBytes(get(clip.getString("clipUrl").replace("127.0.0.1", "10.0.2.2")))
                val retriever = MediaMetadataRetriever()
                try {
                    retriever.setDataSource(file.path)
                    for (slot in 0L..4L) {
                        if (start + slot * 1_000 < afterMillis) continue
                        val frame = retriever.getFrameAtTime(slot * 1_000_000, MediaMetadataRetriever.OPTION_CLOSEST) ?: continue
                        try {
                            val sx = frame.width.toFloat() / screenshot.getInt("width")
                            val sy = frame.height.toFloat() / screenshot.getInt("height")
                            val masked = fields.all { field ->
                                (2..8).all { xi -> (2..8).all { yi ->
                                    val x = ((field.left + field.width * xi / 10) * sx).toInt().coerceIn(0, frame.width - 1)
                                    val y = ((field.top + field.height * yi / 10) * sy).toInt().coerceIn(0, frame.height - 1)
                                    val pixel = frame.getPixel(x, y)
                                    listOf(Color.red(pixel), Color.green(pixel), Color.blue(pixel)).all { it in 78..110 }
                                } }
                            }
                            var colored = 0
                            for (y in 0 until frame.height step 8) for (x in 0 until frame.width step 8) {
                                val p = frame.getPixel(x, y)
                                if (maxOf(Color.red(p), Color.green(p), Color.blue(p)) - minOf(Color.red(p), Color.green(p), Color.blue(p)) > 40) colored++
                            }
                            var errorTextPixels = 0
                            val left = (errorBounds.left * sx).toInt().coerceIn(0, frame.width - 1)
                            val right = (errorBounds.right * sx).toInt().coerceIn(left, frame.width - 1)
                            val top = (errorBounds.top * sy).toInt().coerceIn(0, frame.height - 1)
                            val bottom = (errorBounds.bottom * sy).toInt().coerceIn(top, frame.height - 1)
                            for (y in top..bottom step 2) for (x in left..right step 2) {
                                val pixel = frame.getPixel(x, y)
                                val r = Color.red(pixel)
                                val g = Color.green(pixel)
                                val b = Color.blue(pixel)
                                if (r > g + 25 && r > b + 25 && kotlin.math.abs(g - b) < 35) errorTextPixels++
                            }
                            if (masked && colored > 50 && errorTextPixels > 3) {
                                File(evidence, "verified-masked-login.png").outputStream().use {
                                    assertTrue(frame.compress(Bitmap.CompressFormat.PNG, 100, it))
                                }
                                screenshot.put("verifiedMaskClipIndex", index).put("verifiedMaskSlot", slot)
                                    .put("verifiedMaskAtMillis", start + slot * 1_000)
                                    .put("visibleErrorTextPixels", errorTextPixels)
                                return
                            }
                        } finally {
                            frame.recycle()
                        }
                    }
                } finally {
                    retriever.release()
                }
            }
            SystemClock.sleep(250)
        }
        if (clips().isEmpty()) {
            fail("No automatic MP4 upload reached the collector; populated-input masking was not exercised")
        }
        fail("No uploaded MP4 frame both masked the populated input regions and retained visible app colors")
    }

    private fun awaitErrorTelemetry(session: String): JSONObject {
        val deadline = SystemClock.elapsedRealtime() + 60_000
        val checked = mutableSetOf<Int>()
        var logIndex: Int? = null
        var traceIndex: Int? = null
        while (SystemClock.elapsedRealtime() < deadline) {
            val requests = JSONArray(get("$receiver/_test/receipts").toString(Charsets.UTF_8))
            for (i in 0 until requests.length()) {
                val request = requests.getJSONObject(i)
                val index = request.getInt("requestIndex")
                if (index in checked || request.optInt("status") !in 200..299 || !request.optString("contentType").contains("protobuf")) continue
                checked.add(index)
                val body = get("$receiver/_test/body/$index")
                val decoded = if (request.optString("contentEncoding").equals("gzip", true)) {
                    GZIPInputStream(ByteArrayInputStream(body)).use { it.readBytes() }
                } else body
                val wire = decoded.toString(Charsets.UTF_8)
                if (!wire.contains(session)) continue
                if (request.getString("path").endsWith("/v1/logs") && wire.contains("Login failed")) logIndex = index
                if (request.getString("path").endsWith("/v1/traces") && wire.contains("auth.login")) traceIndex = index
            }
            if (logIndex != null && traceIndex != null) return JSONObject()
                .put("logRequestIndex", logIndex).put("traceRequestIndex", traceIndex)
                .put("sameSessionOnWire", true)
            SystemClock.sleep(500)
        }
        error("The login error log and auth.login trace did not export with the replay session before teardown")
    }

    private fun receipts() = JSONArray(get("$receiver/_automatic/receipts").toString(Charsets.UTF_8))

    private fun clips(): List<JSONObject> {
        val all = receipts()
        return (receiptBaseline until all.length()).map(all::getJSONObject).filter { it.optBoolean("multipart") }
    }

    private fun get(url: String): ByteArray {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 2_000
        connection.readTimeout = 5_000
        return try { connection.inputStream.use { it.readBytes() } } finally { connection.disconnect() }
    }
}

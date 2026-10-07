package com.grafana.quickpizza.features.debug

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.view.Window
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.navigation.NavBackStackEntry
import com.grafana.faro.replay.MaskOptions
import com.grafana.faro.replay.ReplayMaskGeometry
import com.grafana.faro.replay.ReplayMaskRect
import com.grafana.faro.replay.ReplayMaskSource
import java.util.WeakHashMap

/**
 * Explicit geometry for the four inspected QuickPizza demo screens. Their inputs register bounds;
 * a screen root proves this is a supported surface even when it has no inputs. No text is read.
 * Unknown routes, transitions, dialogs, keyboard and incomplete geometry fail closed.
 */
internal class ReplayJourneyGeometry(
    private val onLayoutChanged: (String) -> Unit = {},
) : ReplayMaskSource {
    private val windows = WeakHashMap<Window, MutableMap<Any, Region>>()
    private var epoch = 0L

    fun invalidate() { epoch++ }

    fun register(window: Window, token: Any, entry: NavBackStackEntry, kind: ReplayRegionKind) {
        windows.getOrPut(window) { mutableMapOf() }[token] = Region(entry, kind, null)
        invalidate()
        notifyLayout(entry)
    }

    fun update(window: Window, token: Any, rect: ReplayMaskRect) {
        val values = windows[window] ?: return
        val previous = values[token] ?: return
        if (previous.rect == rect) return
        values[token] = previous.copy(rect = rect)
        invalidate()
        notifyLayout(previous.entry)
    }

    fun remove(window: Window, token: Any) {
        val removed = windows[window]?.remove(token)
        if (removed != null) {
            invalidate()
            notifyLayout(removed.entry)
        }
        if (windows[window]?.isEmpty() == true) windows.remove(window)
    }

    private fun notifyLayout(entry: NavBackStackEntry) {
        // Position changes restart settling; generic invalidation must not feed back into itself.
        SCREEN_ROUTES.entries.firstOrNull { it.value == entry.destination.route }
            ?.let { onLayoutChanged(it.key) }
    }

    override fun snapshot(window: Window, screenName: String, masks: MaskOptions): ReplayMaskGeometry? {
        val expectedRoute = SCREEN_ROUTES[screenName] ?: return null
        val decor = window.peekDecorView() ?: return null
        val insets = ViewCompat.getRootWindowInsets(decor) ?: return null
        if (!decor.hasWindowFocus() || insets.isVisible(WindowInsetsCompat.Type.ime())) return null
        val width = decor.width
        val height = decor.height
        if (width <= 0 || height <= 0) return null
        val regions = windows[window]?.values?.toList() ?: return null
        val entries = regions.map { it.entry }.distinctBy { it.id }
        val entry = entries.singleOrNull() ?: return null
        if (entry.destination.route != expectedRoute || entry.lifecycle.currentState != Lifecycle.State.RESUMED) return null
        val full = ReplayMaskRect(0f, 0f, width.toFloat(), height.toFloat())
        val rects = maskRegions(full, regions.map { it.kind to it.rect }, masks)?.toMutableList() ?: return null
        // Keep platform-owned bars private; the app's known navigation chrome remains visible.
        val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
        if (bars.top > 0) rects.add(ReplayMaskRect(0f, 0f, width.toFloat(), bars.top.toFloat()))
        if (bars.bottom > 0) rects.add(ReplayMaskRect(0f, (height - bars.bottom).toFloat(), width.toFloat(), height.toFloat()))
        if (bars.left > 0) rects.add(ReplayMaskRect(0f, 0f, bars.left.toFloat(), height.toFloat()))
        if (bars.right > 0) rects.add(ReplayMaskRect((width - bars.right).toFloat(), 0f, width.toFloat(), height.toFloat()))
        return ReplayMaskGeometry(width, height, epoch, rects)
    }

    internal fun maskRegions(
        full: ReplayMaskRect,
        regions: List<Pair<ReplayRegionKind, ReplayMaskRect?>>,
        masks: MaskOptions,
    ): List<ReplayMaskRect>? {
        // This integration declares inputs and explicit exclusions, not all text/media nodes.
        // Unsupported stricter policies reject the capture rather than claim complete coverage.
        if (masks.maskAllText || masks.blockAllMedia) return null
        val screens = regions.filter { it.first == ReplayRegionKind.SCREEN }
        if (screens.size != 1) return null
        if (regions.any { (_, rect) -> rect == null || !rect.valid() }) return null
        val screen = checkNotNull(screens.single().second)
        if (screen.left >= screen.right || screen.top >= screen.bottom) return null
        return regions.mapNotNull { (kind, bounds) ->
            val rect = checkNotNull(bounds)
            if (kind == ReplayRegionKind.ALWAYS || (kind == ReplayRegionKind.INPUT && masks.maskAllInputs)) {
                // Zero-area clipped controls expose no pixels. Invalid bounds were rejected above.
                val clipped = ReplayMaskRect(maxOf(full.left, rect.left), maxOf(full.top, rect.top),
                    minOf(full.right, rect.right), minOf(full.bottom, rect.bottom))
                clipped.takeIf { it.left < it.right && it.top < it.bottom }
            } else null
        }
    }

    private fun ReplayMaskRect.valid(): Boolean =
        listOf(left, top, right, bottom).all { it.isFinite() } && left <= right && top <= bottom

    private data class Region(val entry: NavBackStackEntry, val kind: ReplayRegionKind, val rect: ReplayMaskRect?)

    private companion object {
        val SCREEN_ROUTES = mapOf("Login" to "login", "Home" to "home", "About" to "about", "Debug" to "debug")
    }
}

internal enum class ReplayRegionKind { SCREEN, INPUT, ALWAYS }

/** Apply once to a supported screen's root, after auditing every input on that screen. */
internal fun Modifier.replayScreenSurface(): Modifier = replayRegion(ReplayRegionKind.SCREEN)

/** Covers the whole input, including its value, cursor and any suggestion inside its bounds. */
internal fun Modifier.replayInput(): Modifier = replayRegion(ReplayRegionKind.INPUT)

internal fun Modifier.replayAlwaysMask(): Modifier = replayRegion(ReplayRegionKind.ALWAYS)

internal fun Modifier.replayRegion(kind: ReplayRegionKind): Modifier = composed {
    if (ReplayJourney.recorder == null) return@composed Modifier
    val activity = LocalContext.current.replayActivity()
    val entry = LocalLifecycleOwner.current as? NavBackStackEntry
    val token = remember { Any() }
    val window = activity.window
    DisposableEffect(window, token, entry, kind) {
        val observer = LifecycleEventObserver { _, _ -> ReplayJourney.geometry.invalidate() }
        if (entry != null) {
            ReplayJourney.geometry.register(window, token, entry, kind)
            entry.lifecycle.addObserver(observer)
        }
        onDispose {
            entry?.lifecycle?.removeObserver(observer)
            ReplayJourney.geometry.remove(window, token)
        }
    }
    onGloballyPositioned { coordinates ->
        if (entry != null) {
            val r = coordinates.boundsInWindow()
            ReplayJourney.geometry.update(window, token, ReplayMaskRect(r.left, r.top, r.right, r.bottom))
        }
    }
}

internal fun Context.replayActivity(): Activity {
    var current = this
    while (current is ContextWrapper) {
        if (current is Activity) return current
        current = current.baseContext
    }
    error("Replay controls require an Activity")
}

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
 * Conservative QuickPizza integration policy: mask the entire window except explicitly marked,
 * static, public labels. No semantics reflection, text collection or automatic coverage claim.
 * Credentials, media, dynamic content, system bars and every unregistered surface remain covered.
 */
internal class ReplayJourneyGeometry : ReplayMaskSource {
    private val windows = WeakHashMap<Window, MutableMap<Any, PublicLabel>>()
    private var epoch = 0L

    fun invalidate() { epoch++ }
    fun update(window: Window, token: Any, entry: NavBackStackEntry, rect: ReplayMaskRect) {
        val values = windows.getOrPut(window) { mutableMapOf() }
        val label = PublicLabel(entry, rect)
        if (values.put(token, label) != label) invalidate()
    }
    fun remove(window: Window, token: Any) {
        if (windows[window]?.remove(token) != null) invalidate()
        if (windows[window]?.isEmpty() == true) windows.remove(window)
    }

    override fun snapshot(window: Window, screenName: String, masks: MaskOptions): ReplayMaskGeometry? {
        if (screenName !in setOf("Login", "Home")) return null
        val decor = window.peekDecorView() ?: return null
        if (ViewCompat.getRootWindowInsets(decor)?.isVisible(WindowInsetsCompat.Type.ime()) != false) return null
        val width = decor.width
        val height = decor.height
        if (width <= 0 || height <= 0) return null
        val labels = windows[window]?.values?.toList() ?: return null
        if (labels.isEmpty()) return null
        // NavHost retains outgoing compositions until a transition completes. Never use their
        // holes for the incoming screen, even when their bounds happen to remain unchanged.
        val entries = labels.map { it.entry }.distinctBy { it.id }
        val entry = entries.singleOrNull() ?: return null
        val expectedRoute = if (screenName == "Login") "login" else "home"
        if (entry.destination.route != expectedRoute || entry.lifecycle.currentState != Lifecycle.State.RESUMED) return null
        val publicLabels = labels.map { it.rect }
        val full = ReplayMaskRect(0f, 0f, width.toFloat(), height.toFloat())
        val rects = if (masks.maskAllText) listOf(full) else complement(full, publicLabels) ?: return null
        return ReplayMaskGeometry(width, height, epoch, rects)
    }

    internal fun complement(full: ReplayMaskRect, publicLabels: List<ReplayMaskRect>): List<ReplayMaskRect>? {
        var masked = listOf(full)
        for (label in publicLabels) {
            if (!listOf(label.left, label.top, label.right, label.bottom).all { it.isFinite() } ||
                label.left > label.right || label.top > label.bottom) return null
            // Compose returns Rect.Zero for labels clipped outside a scroll viewport. They open
            // no hole; the surrounding content stays masked. Inverted/non-finite bounds reject.
            if (label.left == label.right || label.top == label.bottom) continue
            val next = ArrayList<ReplayMaskRect>()
            for (region in masked) {
                val left = maxOf(region.left, label.left)
                val right = minOf(region.right, label.right)
                val top = maxOf(region.top, label.top)
                val bottom = minOf(region.bottom, label.bottom)
                if (left >= right || top >= bottom) { next.add(region); continue }
                if (region.top < top) next.add(ReplayMaskRect(region.left, region.top, region.right, top))
                if (bottom < region.bottom) next.add(ReplayMaskRect(region.left, bottom, region.right, region.bottom))
                if (region.left < left) next.add(ReplayMaskRect(region.left, top, left, bottom))
                if (right < region.right) next.add(ReplayMaskRect(right, top, region.right, bottom))
            }
            masked = next
        }
        return masked
    }

    private data class PublicLabel(val entry: NavBackStackEntry, val rect: ReplayMaskRect)
}

/** Use ONLY on a hard-coded public text label, never on a parent, input, image or dynamic text. */
internal fun Modifier.replayPublicLabel(): Modifier = composed {
    if (ReplayJourney.recorder == null) return@composed Modifier
    val activity = LocalContext.current.replayActivity()
    val entry = LocalLifecycleOwner.current as? NavBackStackEntry
    val token = remember { Any() }
    val window = activity.window
    DisposableEffect(window, token, entry) {
        val observer = LifecycleEventObserver { _, _ -> ReplayJourney.geometry.invalidate() }
        entry?.lifecycle?.addObserver(observer)
        onDispose {
            entry?.lifecycle?.removeObserver(observer)
            ReplayJourney.geometry.remove(window, token)
        }
    }
    onGloballyPositioned { coordinates ->
        if (entry != null) {
            val r = coordinates.boundsInWindow()
            ReplayJourney.geometry.update(window, token, entry, ReplayMaskRect(r.left, r.top, r.right, r.bottom))
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

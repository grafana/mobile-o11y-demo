package com.grafana.quickpizza.features.debug

import android.graphics.RectF
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.node.GlobalPositionAwareModifierNode
import androidx.compose.ui.node.ModifierNodeElement
import androidx.compose.ui.platform.InspectorInfo
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.semantics

/**
 * Marks a composable that replay must cover before encoding.
 * The password field on Login uses this. Capture reads [GrafanaNoCaptureRegistry].
 */
val GrafanaNoCapture = SemanticsPropertyKey<Unit>("GrafanaNoCapture")

fun Modifier.grafanaNoCapture(): Modifier = this
    .semantics { this[GrafanaNoCapture] = Unit }
    .then(GrafanaNoCaptureElement)

internal object GrafanaNoCaptureRegistry {
    private val rects = LinkedHashMap<Any, RectF>()

    fun put(key: Any, rect: RectF) {
        synchronized(this) {
            rects[key] = RectF(rect)
        }
    }

    fun remove(key: Any) {
        synchronized(this) {
            rects.remove(key)
        }
    }

    fun snapshot(): List<RectF> = synchronized(this) {
        rects.values.map { RectF(it) }
    }
}

private object GrafanaNoCaptureElement : ModifierNodeElement<GrafanaNoCaptureNode>() {
    override fun create(): GrafanaNoCaptureNode = GrafanaNoCaptureNode()

    override fun update(node: GrafanaNoCaptureNode) = Unit

    override fun InspectorInfo.inspectableProperties() {
        name = "grafanaNoCapture"
    }

    override fun equals(other: Any?): Boolean = other === this

    override fun hashCode(): Int = "grafanaNoCapture".hashCode()
}

private class GrafanaNoCaptureNode : Modifier.Node(), GlobalPositionAwareModifierNode {
    override fun onGloballyPositioned(coordinates: LayoutCoordinates) {
        if (!coordinates.isAttached) return
        val bounds = coordinates.boundsInWindow()
        GrafanaNoCaptureRegistry.put(
            this,
            RectF(bounds.left, bounds.top, bounds.right, bounds.bottom),
        )
    }

    override fun onDetach() {
        GrafanaNoCaptureRegistry.remove(this)
        super.onDetach()
    }
}

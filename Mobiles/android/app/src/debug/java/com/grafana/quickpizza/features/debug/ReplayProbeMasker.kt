package com.grafana.quickpizza.features.debug

import android.app.Activity
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.util.Log
import android.view.View
import android.view.ViewGroup
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsOwner
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull

private const val TAG = "ReplayProbe"
private const val MASK_COLOR = 0xFF5E5E5E.toInt()
private const val MAX_TREE_DEPTH = 40

/**
 * Paints mask rectangles onto the captured bitmap before it is encoded.
 * Explicit [grafanaNoCapture] bounds are always included. Compose semantics supply the
 * automatic masks according to [ReplayProbeMask.maskAllText], [ReplayProbeMask.maskAllInputs],
 * and [ReplayProbeMask.blockAllMedia].
 */
internal object ReplayProbeMasker {
    fun collect(activity: Activity): List<RectF> {
        val decor = activity.window.decorView
        val width = decor.width
        val height = decor.height
        if (width <= 0 || height <= 0) return emptyList()
        val maxArea = width * height * 0.75f
        val regions = ArrayList<RectF>()
        var explicit = 0
        var automatic = 0

        fun add(rect: RectF?): Boolean {
            if (rect == null) return false
            if (rect.width() * rect.height() > maxArea) return false
            regions.add(rect)
            return true
        }

        for (windowRect in GrafanaNoCaptureRegistry.snapshot()) {
            if (add(ReplayProbeMask.clipToBitmap(windowRect, width, height))) {
                explicit += 1
            }
        }

        val composeViews = ArrayList<View>()
        findComposeViews(decor, composeViews)
        for (view in composeViews) {
            val owner = semanticsOwner(view)
            if (owner == null) {
                Log.w(TAG, "Compose view has no semantics owner: ${view.javaClass.name}")
                continue
            }
            val origin = IntArray(2)
            view.getLocationInWindow(origin)
            automatic += walkSemantics(owner.unmergedRootSemanticsNode, origin[0], origin[1], width, height, maxArea, regions, depth = 0)
        }
        Log.i(
            TAG,
            "Mask flags text=${ReplayProbeMask.maskAllText} inputs=${ReplayProbeMask.maskAllInputs} media=${ReplayProbeMask.blockAllMedia}",
        )
        Log.i(TAG, "Mask regions explicit=$explicit automatic=$automatic")
        return regions
    }

    fun paint(bitmap: android.graphics.Bitmap, regions: List<RectF>) {
        if (regions.isEmpty()) {
            Log.w(TAG, "Mask found no regions")
            return
        }
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = MASK_COLOR
            style = Paint.Style.FILL
        }
        val density = if (bitmap.density > 0) bitmap.density else 160
        val radius = 8f * density / 160f
        for (region in regions) {
            canvas.drawRoundRect(region, radius, radius, paint)
        }
        Log.i(TAG, "Masked ${regions.size} regions before encode")
    }

    private fun walkSemantics(
        node: SemanticsNode,
        originX: Int,
        originY: Int,
        bitmapWidth: Int,
        bitmapHeight: Int,
        maxArea: Float,
        regions: MutableList<RectF>,
        depth: Int,
    ): Int {
        if (depth > MAX_TREE_DEPTH) return 0
        var count = 0
        val config = node.config
        if (!config.contains(SemanticsProperties.InvisibleToUser)) {
            val text = config.getOrNull(SemanticsProperties.Text).orEmpty().joinToString(separator = "") { it.text }
            val editable = config.contains(SemanticsProperties.EditableText)
            val password = config.contains(SemanticsProperties.Password)
            val role = config.getOrNull(SemanticsProperties.Role)
            val description = config.getOrNull(SemanticsProperties.ContentDescription).orEmpty().joinToString()
            val image = role == Role.Image
            if (ReplayProbeMask.shouldAutoMask(text, editable, password, image)) {
                val rect = windowRect(node.boundsInRoot, originX, originY)
                val clipped = ReplayProbeMask.clipToBitmap(rect, bitmapWidth, bitmapHeight)
                if (clipped != null && clipped.width() * clipped.height() <= maxArea) {
                    regions.add(clipped)
                    count += 1
                    val kind = when {
                        password -> "password"
                        editable -> "input"
                        image -> "image"
                        text.isNotBlank() -> "text"
                        else -> "described"
                    }
                    val label = text.ifBlank { description }.take(40)
                    Log.i(TAG, "auto-mask $kind \"$label\"")
                }
            }
        }
        for (child in node.children) {
            count += walkSemantics(child, originX, originY, bitmapWidth, bitmapHeight, maxArea, regions, depth + 1)
        }
        return count
    }

    private fun windowRect(bounds: Rect, originX: Int, originY: Int): RectF {
        return RectF(
            originX + bounds.left,
            originY + bounds.top,
            originX + bounds.right,
            originY + bounds.bottom,
        )
    }

    private fun semanticsOwner(view: View): SemanticsOwner? {
        val method = view.javaClass.methods.firstOrNull { candidate ->
            candidate.parameterTypes.isEmpty() && candidate.name.startsWith("getSemanticsOwner")
        } ?: return null
        method.isAccessible = true
        return method.invoke(view) as? SemanticsOwner
    }

    private fun findComposeViews(view: View, out: MutableList<View>) {
        if (view.javaClass.name == "androidx.compose.ui.platform.AndroidComposeView") {
            out.add(view)
        }
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) {
                findComposeViews(view.getChildAt(index), out)
            }
        }
    }
}

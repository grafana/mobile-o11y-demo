package com.grafana.quickpizza.features.debug

import android.graphics.Rect
import android.graphics.RectF

/**
 * Decides which Compose semantics nodes get painted over before the probe encodes a frame.
 * The three flags are independent: text does not include inputs, and media does not include text or inputs.
 * Callers drop regions larger than the screen so a root node cannot cover the whole capture.
 *
 * First probe run: inputs and media on, text off.
 */
internal object ReplayProbeMask {
    const val maskAllText = false
    const val maskAllInputs = true
    const val blockAllMedia = true

    fun shouldAutoMask(
        text: String,
        editable: Boolean,
        password: Boolean,
        image: Boolean,
        maskAllText: Boolean = this.maskAllText,
        maskAllInputs: Boolean = this.maskAllInputs,
        blockAllMedia: Boolean = this.blockAllMedia,
    ): Boolean {
        if (maskAllInputs && (password || editable)) return true
        if (blockAllMedia && image) return true
        return maskAllText && !editable && !password && text.isNotBlank()
    }

    fun clipToBitmap(rect: RectF, bitmapWidth: Int, bitmapHeight: Int): RectF? {
        if (bitmapWidth <= 0 || bitmapHeight <= 0) return null
        val left = rect.left.coerceIn(0f, bitmapWidth.toFloat())
        val top = rect.top.coerceIn(0f, bitmapHeight.toFloat())
        val right = rect.right.coerceIn(0f, bitmapWidth.toFloat())
        val bottom = rect.bottom.coerceIn(0f, bitmapHeight.toFloat())
        if (right - left < 1f || bottom - top < 1f) return null
        return RectF(left, top, right, bottom)
    }

    fun screenToBitmap(screen: Rect, windowX: Int, windowY: Int, bitmapWidth: Int, bitmapHeight: Int): RectF? {
        return clipToBitmap(
            RectF(
                (screen.left - windowX).toFloat(),
                (screen.top - windowY).toFloat(),
                (screen.right - windowX).toFloat(),
                (screen.bottom - windowY).toFloat(),
            ),
            bitmapWidth,
            bitmapHeight,
        )
    }
}

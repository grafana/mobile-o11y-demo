package com.grafana.quickpizza.features.debug

import com.grafana.faro.replay.ReplayMaskRect
import org.junit.Assert.*
import org.junit.Test

class ReplayJourneyGeometryTest {
    @Test fun `unregistered pixels stay covered around multiple public labels`() {
        val source = ReplayJourneyGeometry()
        val holes = listOf(ReplayMaskRect(2f, 2f, 4f, 4f), ReplayMaskRect(6f, 3f, 9f, 7f))
        val masks = checkNotNull(source.complement(ReplayMaskRect(0f, 0f, 10f, 10f), holes))
        for (y in 0..9) for (x in 0..9) {
            fun ReplayMaskRect.contains() = x + .5f in left..<right && y + .5f in top..<bottom
            assertEquals("$x,$y", !holes.any { it.contains() }, masks.any { it.contains() })
        }
    }
    @Test fun `overlapping or clipped labels cannot clear unrelated pixels`() {
        val source = ReplayJourneyGeometry()
        val full = ReplayMaskRect(0f, 0f, 10f, 10f)
        val masks = checkNotNull(source.complement(full,
            listOf(ReplayMaskRect(-10f, -10f, 2f, 2f), ReplayMaskRect(1f, 1f, 3f, 3f))))
        assertTrue(masks.any { 5f in it.left..<it.right && 5f in it.top..<it.bottom })
    }
    @Test fun `clipped out public labels leave the full window masked`() {
        val source = ReplayJourneyGeometry()
        val full = ReplayMaskRect(0f, 0f, 10f, 10f)
        assertEquals(listOf(full), source.complement(full, listOf(
            ReplayMaskRect(0f, 0f, 0f, 0f),
            ReplayMaskRect(4f, 2f, 4f, 8f),
            ReplayMaskRect(2f, 4f, 8f, 4f),
        )))
        assertEquals(listOf(full), source.complement(full, emptyList()))
    }
    @Test fun `zero area labels do not prevent masking around a visible label`() {
        val source = ReplayJourneyGeometry()
        val full = ReplayMaskRect(0f, 0f, 10f, 10f)
        val visible = ReplayMaskRect(2f, 2f, 4f, 4f)
        assertEquals(source.complement(full, listOf(visible)),
            source.complement(full, listOf(ReplayMaskRect(0f, 0f, 0f, 0f), visible)))
    }
    @Test fun `inverted or nonfinite zero area bounds still fail closed`() {
        val source = ReplayJourneyGeometry()
        val full = ReplayMaskRect(0f, 0f, 10f, 10f)
        assertNull(source.complement(full, listOf(ReplayMaskRect(4f, 0f, 2f, 0f))))
        assertNull(source.complement(full, listOf(ReplayMaskRect(Float.POSITIVE_INFINITY, 0f, Float.POSITIVE_INFINITY, 0f))))
    }
    @Test fun `invalid public bounds fail closed`() {
        val source = ReplayJourneyGeometry()
        assertNull(source.complement(ReplayMaskRect(0f,0f,10f,10f), listOf(ReplayMaskRect(Float.NaN,0f,3f,3f))))
    }
}

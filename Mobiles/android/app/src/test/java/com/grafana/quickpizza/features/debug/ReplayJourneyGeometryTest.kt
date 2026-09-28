package com.grafana.quickpizza.features.debug

import com.grafana.faro.replay.MaskOptions
import com.grafana.faro.replay.ReplayMaskRect
import org.junit.Assert.*
import org.junit.Test

class ReplayJourneyGeometryTest {
    private val source = ReplayJourneyGeometry()
    private val full = ReplayMaskRect(0f, 0f, 100f, 200f)
    private val root = ReplayRegionKind.SCREEN to full
    private val defaults = MaskOptions(maskAllText = false, maskAllInputs = true, blockAllMedia = false)

    @Test fun `known input-free surface preserves app colors`() {
        assertEquals(emptyList<ReplayMaskRect>(), source.maskRegions(full, listOf(root), defaults))
    }
    @Test fun `only inputs and explicit exclusions are masked`() {
        val input = ReplayMaskRect(10f, 40f, 90f, 60f)
        val password = ReplayMaskRect(10f, 70f, 90f, 90f)
        val masks = source.maskRegions(full, listOf(root,
            ReplayRegionKind.INPUT to input, ReplayRegionKind.ALWAYS to password), defaults)
        assertEquals(listOf(input, password), masks)
        // Background, headings, icons and public media retain their original pixels.
        assertFalse(checkNotNull(masks).any { 5f in it.left..<it.right && 5f in it.top..<it.bottom })
    }
    @Test fun `password and explicit exclusions remain covered with input masking disabled`() {
        val secret = ReplayMaskRect(10f, 70f, 90f, 90f)
        assertEquals(listOf(secret), source.maskRegions(full, listOf(root,
            ReplayRegionKind.INPUT to ReplayMaskRect(10f, 40f, 90f, 60f),
            ReplayRegionKind.ALWAYS to secret), defaults.copy(maskAllInputs = false)))
    }
    @Test fun `unknown root transition roots and unpositioned controls reject capture`() {
        assertNull(source.maskRegions(full, emptyList(), defaults))
        assertNull(source.maskRegions(full, listOf(root, root), defaults))
        assertNull(source.maskRegions(full, listOf(root, ReplayRegionKind.INPUT to null), defaults))
        assertNull(source.maskRegions(full, listOf(ReplayRegionKind.SCREEN to ReplayMaskRect(0f,0f,0f,0f)), defaults))
    }
    @Test fun `moving bounds replace old masks and clipped controls expose no pixels`() {
        val old = ReplayMaskRect(10f, 40f, 90f, 60f)
        val moved = ReplayMaskRect(10f, 20f, 90f, 40f)
        assertEquals(listOf(old), source.maskRegions(full, listOf(root, ReplayRegionKind.INPUT to old), defaults))
        assertEquals(listOf(moved), source.maskRegions(full, listOf(root, ReplayRegionKind.INPUT to moved,
            ReplayRegionKind.INPUT to ReplayMaskRect(0f,0f,0f,0f)), defaults))
    }
    @Test fun `invalid bounds and unsupported broader policies fail closed`() {
        for (bounds in listOf(ReplayMaskRect(Float.NaN,0f,3f,3f), ReplayMaskRect(4f,0f,2f,0f))) {
            assertNull(source.maskRegions(full, listOf(root, ReplayRegionKind.INPUT to bounds), defaults))
        }
        assertNull(source.maskRegions(full, listOf(root), defaults.copy(maskAllText = true)))
        assertNull(source.maskRegions(full, listOf(root), defaults.copy(blockAllMedia = true)))
    }
}

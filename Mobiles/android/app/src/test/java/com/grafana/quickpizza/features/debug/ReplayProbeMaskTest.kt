package com.grafana.quickpizza.features.debug

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReplayProbeMaskTest {

    @Test
    fun probeDefaultsMaskInputsAndMediaAndLeaveTextVisible() {
        assertFalse(ReplayProbeMask.maskAllText)
        assertTrue(ReplayProbeMask.maskAllInputs)
        assertTrue(ReplayProbeMask.blockAllMedia)
        assertFalse(ReplayProbeMask.shouldAutoMask("Welcome", editable = false, password = false, image = false))
        assertTrue(ReplayProbeMask.shouldAutoMask("", editable = true, password = false, image = false))
        assertTrue(ReplayProbeMask.shouldAutoMask("", editable = true, password = true, image = false))
        assertTrue(ReplayProbeMask.shouldAutoMask("", editable = false, password = false, image = true))
    }

    @Test
    fun eachFlagCoversOnlyItsCategory() {
        assertTrue(
            ReplayProbeMask.shouldAutoMask(
                "Welcome",
                editable = false,
                password = false,
                image = false,
                maskAllText = true,
                maskAllInputs = false,
                blockAllMedia = false,
            ),
        )
        assertFalse(
            ReplayProbeMask.shouldAutoMask(
                "Welcome",
                editable = true,
                password = false,
                image = false,
                maskAllText = true,
                maskAllInputs = false,
                blockAllMedia = false,
            ),
        )
        assertFalse(
            ReplayProbeMask.shouldAutoMask(
                "",
                editable = false,
                password = false,
                image = true,
                maskAllText = false,
                maskAllInputs = true,
                blockAllMedia = false,
            ),
        )
        assertFalse(
            ReplayProbeMask.shouldAutoMask(
                "Welcome",
                editable = false,
                password = false,
                image = false,
                maskAllText = false,
                maskAllInputs = false,
                blockAllMedia = true,
            ),
        )
    }

    @Test
    fun allThreeFlagsMaskTextInputsAndImages() {
        assertTrue(
            ReplayProbeMask.shouldAutoMask(
                "Welcome",
                editable = false,
                password = false,
                image = false,
                maskAllText = true,
                maskAllInputs = true,
                blockAllMedia = true,
            ),
        )
        assertTrue(
            ReplayProbeMask.shouldAutoMask(
                "",
                editable = true,
                password = false,
                image = false,
                maskAllText = true,
                maskAllInputs = true,
                blockAllMedia = true,
            ),
        )
        assertTrue(
            ReplayProbeMask.shouldAutoMask(
                "",
                editable = false,
                password = false,
                image = true,
                maskAllText = true,
                maskAllInputs = true,
                blockAllMedia = true,
            ),
        )
    }
}

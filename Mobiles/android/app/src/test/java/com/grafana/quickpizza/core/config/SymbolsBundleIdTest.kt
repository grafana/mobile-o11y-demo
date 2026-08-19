package com.grafana.quickpizza.core.config

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SymbolsBundleIdTest {

    @Test
    fun formatUsesVersionCodeBeforeVersionName() {
        assertEquals(
            "com.grafana.quickpizza.android@1@1.0.0",
            SymbolsBundleId.format("com.grafana.quickpizza.android", 1L, "1.0.0"),
        )
    }

    @Test
    fun validateAcceptsEncodedTriple() {
        assertTrue(SymbolsBundleId.validate("com.grafana.quickpizza.android@1@1.0.0"))
    }

    @Test
    fun validateRejectsNonNumericVersionCode() {
        assertFalse(SymbolsBundleId.validate("com.app@beta@1.0"))
    }
}

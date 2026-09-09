package com.grafana.quickpizza.core.o11y

import java.lang.reflect.Modifier
import org.junit.Assert.assertTrue
import org.junit.Test

class OTelServiceTest {
    @Test
    fun `runtime field is volatile for unsynchronized readers`() {
        val runtimeField = OTelService::class.java.getDeclaredField("rum")

        assertTrue(
            "Runtime getters need volatile visibility without the initialize lock",
            Modifier.isVolatile(runtimeField.modifiers),
        )
    }
}

package com.grafana.quickpizza.core.o11y

import com.grafana.quickpizza.core.o11y.otelfixture.Fixture
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class UnobfuscateTest {

    @Test
    fun `invokes the public unobfuscate method on a package-private class in another package`() {
        val target = Any()
        val obfuscator = Fixture.obfuscate(target)

        val result = obfuscator.unobfuscate<Any>()

        assertEquals(target, result)
    }

    @Test
    fun `returns null when the receiver has no unobfuscate method`() {
        val result = Fixture.noUnobfuscateMethod().unobfuscate<Any>()

        assertNull(result)
    }
}

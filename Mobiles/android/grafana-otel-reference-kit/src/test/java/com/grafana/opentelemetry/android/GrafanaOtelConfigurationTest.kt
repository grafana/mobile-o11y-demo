package com.grafana.opentelemetry.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.time.Duration

class GrafanaOtelConfigurationTest {
    @Test
    fun `snapshots caller-owned headers`() {
        val headers = mutableMapOf("Authorization" to "Bearer original")

        val configuration = validConfiguration(headers = headers)
        headers["Authorization"] = "Bearer changed"

        assertEquals("Bearer original", configuration.headers["Authorization"])
    }

    @Test
    fun `requires an OTLP endpoint`() {
        assertThrows(IllegalArgumentException::class.java) {
            validConfiguration(otlpEndpoint = " ")
        }
    }

    @Test
    fun `requires a service name`() {
        assertThrows(IllegalArgumentException::class.java) {
            validConfiguration(serviceName = "")
        }
    }

    @Test
    fun `requires positive session limits`() {
        assertThrows(IllegalArgumentException::class.java) {
            validConfiguration(sessionBackgroundInactivityTimeout = Duration.ofSeconds(-1))
        }
        assertThrows(IllegalArgumentException::class.java) {
            validConfiguration(sessionMaxLifetime = Duration.ZERO)
        }
    }

    @Test
    fun `rejects blank optional resource values`() {
        assertThrows(IllegalArgumentException::class.java) {
            validConfiguration(serviceNamespace = " ")
        }
        assertThrows(IllegalArgumentException::class.java) {
            validConfiguration(serviceVersion = "")
        }
    }

    @Test
    fun `rejects blank header names`() {
        assertThrows(IllegalArgumentException::class.java) {
            validConfiguration(headers = mapOf(" " to "value"))
        }
    }

    private fun validConfiguration(
        otlpEndpoint: String = "https://collector.example.test/otlp/app-key",
        serviceName: String = "quickpizza-android",
        headers: Map<String, String> = emptyMap(),
        serviceNamespace: String? = null,
        serviceVersion: String? = null,
        sessionBackgroundInactivityTimeout: Duration = Duration.ofSeconds(30),
        sessionMaxLifetime: Duration = Duration.ofSeconds(60),
    ) = GrafanaOtelConfiguration(
        otlpEndpoint = otlpEndpoint,
        serviceName = serviceName,
        headers = headers,
        serviceNamespace = serviceNamespace,
        serviceVersion = serviceVersion,
        sessionBackgroundInactivityTimeout = sessionBackgroundInactivityTimeout,
        sessionMaxLifetime = sessionMaxLifetime,
    )
}

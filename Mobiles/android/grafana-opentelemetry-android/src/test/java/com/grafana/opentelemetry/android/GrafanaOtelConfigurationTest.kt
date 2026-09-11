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
        assertThrows(IllegalArgumentException::class.java) {
            validConfiguration(otlpEndpoint = "collector.example.test/otlp/app-key")
        }
        assertThrows(IllegalArgumentException::class.java) {
            validConfiguration(otlpEndpoint = "ftp://collector.example.test/otlp/app-key")
        }
        assertThrows(IllegalArgumentException::class.java) {
            validConfiguration(otlpEndpoint = "HTTPS://collector.example.test/otlp/app-key")
        }
        assertThrows(IllegalArgumentException::class.java) {
            validConfiguration(otlpEndpoint = "https://collector.example.test/otlp?tenant=1")
        }
        assertThrows(IllegalArgumentException::class.java) {
            validConfiguration(otlpEndpoint = "https://collector.example.test/otlp#fragment")
        }

        assertEquals(
            "http://10.0.2.2:8001/otlp/app-key",
            validConfiguration(otlpEndpoint = "http://10.0.2.2:8001/otlp/app-key").otlpEndpoint,
        )
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

    @Test
    fun `rejects headers that the HTTP exporter cannot send`() {
        assertThrows(IllegalArgumentException::class.java) {
            validConfiguration(headers = mapOf("Authorization\nInjected" to "value"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            validConfiguration(headers = mapOf("Authorization" to "Bearer token\r\nInjected: true"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            validConfiguration(headers = mapOf("X Scope OrgID" to "tenant"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            validConfiguration(headers = mapOf("X-Scope-OrgID" to "tenant\u2014one"))
        }

        assertEquals(
            "tenant\tone",
            validConfiguration(headers = mapOf("X-Scope-OrgID" to "tenant\tone"))
                .headers["X-Scope-OrgID"],
        )
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

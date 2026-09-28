package com.grafana.quickpizza.core.config

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReplayEndpointTest {
    @Test
    fun `uses resolved runtime endpoint unchanged`() {
        val runtime = config("https://collector.example.com/otlp/runtime-app-key")
        val endpoint = checkNotNull(runtime.replayEndpoint())
        assertEquals(runtime.otlpEndpoint, endpoint.ingestEndpoint)
        assertFalse(endpoint.allowLoopbackHttp)
        assertFalse(endpoint.toString().contains("runtime-app-key"))
    }

    @Test
    fun `accepts local demo addresses and collect endpoint`() {
        listOf("localhost", "127.0.0.1", "10.0.2.2", "LOCALHOST").forEach { host ->
            val value = "http://$host:18002/otlp/demo-key"
            val endpoint = checkNotNull(config(value).replayEndpoint())
            assertEquals(value, endpoint.ingestEndpoint)
            assertTrue(endpoint.allowLoopbackHttp)
        }
        assertEquals(
            "https://collector.example.com/collect/demo-key",
            config("https://collector.example.com/collect/demo-key").replayEndpoint()?.ingestEndpoint,
        )
    }

    @Test
    fun `invalid and unsupported endpoints disable optional replay`() {
        listOf(
            "", " ", "not a url", "https://bad host/otlp", "https:///otlp",
            "https://collector.example.com/otlp#fragment",
            "https://user:password@collector.example.com/otlp",
            "https://collector.example.com:0/otlp", "https://collector.example.com:65536/otlp",
            "http://collector.example.com/otlp", "ftp://localhost/otlp",
            "https://collector.example.com/v1/logs", "mailto:person@example.com",
        ).forEach { endpoint ->
            assertNull("Should reject unsupported endpoint", config(endpoint).replayEndpoint())
        }
    }

    private fun config(endpoint: String) = RuntimeConfig(
        backendBaseUrl = "http://localhost:3333",
        otlpEndpoint = endpoint,
        otlpInstanceId = "",
        otlpApiKey = "",
        otlpAuthHeader = null,
        diskBufferingEnabled = false,
    )
}

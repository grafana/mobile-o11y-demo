package com.grafana.quickpizza.features.replay

import io.opentelemetry.android.OpenTelemetryRum
import io.opentelemetry.android.session.Session
import io.opentelemetry.android.session.SessionProvider
import io.opentelemetry.api.OpenTelemetry
import io.opentelemetry.api.common.Attributes
import io.opentelemetry.sdk.common.Clock
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Duration

class QuickPizzaSessionHostTest {
    private val clock = MutableClock(START_NANOS)
    private val host = QuickPizzaSessionHost()

    @Test
    fun `observer session is reported without reading the session provider`() {
        host.attach(rumThatFailsIfSessionProviderIsRead(clock))

        host.onSessionStarted(session("abc", START_NANOS), session("", 0L))

        val snapshot = host.currentSessionSnapshot()
        assertEquals("abc", snapshot.sessionId)
        assertTrue(snapshot.isRumSampled)
        assertEquals(1L, snapshot.invalidationEpoch)
        assertEquals(START_NANOS / 1_000_000L, host.captureTimeMillis())
    }

    @Test
    fun `ending the current session clears the id and advances the epoch`() {
        host.onSessionStarted(session("abc", START_NANOS), session("", 0L))

        host.onSessionEnded(session("abc", START_NANOS))

        val snapshot = host.currentSessionSnapshot()
        assertNull(snapshot.sessionId)
        assertFalse(snapshot.isRumSampled)
        assertEquals(2L, snapshot.invalidationEpoch)
    }

    @Test
    fun `a session past the sdk max lifetime is not replay eligible`() {
        host.attach(rumThatFailsIfSessionProviderIsRead(clock))
        host.onSessionStarted(session("abc", START_NANOS), session("", 0L))
        clock.nanos = START_NANOS + Duration.ofHours(4).toNanos()

        val snapshot = host.currentSessionSnapshot()

        assertNull(snapshot.sessionId)
        assertFalse(snapshot.isRumSampled)
    }

    private class MutableClock(var nanos: Long) : Clock {
        override fun now(): Long = nanos
        override fun nanoTime(): Long = nanos
    }

    private class FakeSession(
        override val id: String,
        override val startTimestamp: Long,
    ) : Session

    private fun session(id: String, startTimestamp: Long): Session = FakeSession(id, startTimestamp)

    private fun rumThatFailsIfSessionProviderIsRead(clock: Clock): OpenTelemetryRum =
        object : OpenTelemetryRum {
            override val openTelemetry: OpenTelemetry
                get() = error("unused")
            override val sessionProvider: SessionProvider
                get() = error("session provider must stay unread")
            override val clock: Clock = clock

            override fun emitEvent(eventName: String, body: String, attributes: Attributes) =
                error("unused")

            override fun shutdown() = Unit
        }

    private companion object {
        const val START_NANOS = 10_000_000_000L
    }
}

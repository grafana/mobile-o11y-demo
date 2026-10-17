package com.grafana.quickpizza.features.debug

import io.opentelemetry.android.OpenTelemetryRum
import io.opentelemetry.android.session.Session
import io.opentelemetry.android.session.SessionProvider
import io.opentelemetry.api.OpenTelemetry
import io.opentelemetry.api.common.Attributes
import io.opentelemetry.sdk.common.Clock
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Test

class ReplaySessionBridgeTest {
    @Test
    fun `unattached bridge provides no invented identity or timestamp`() {
        val bridge = ReplaySessionBridge()

        assertNull(bridge.resolveSessionIdForUserCapture())
        assertNull(bridge.epochMillis())
        assertEquals(0L, bridge.invalidationEpoch())
    }

    @Test
    fun `attachment clock and observer notifications never look up the SDK session`() {
        val bridge = ReplaySessionBridge()
        val rum = FakeRum()
        var notifications = 0
        val subscription = bridge.subscribe { notifications++ }

        bridge.attach(rum)
        assertEquals(1L, bridge.invalidationEpoch())
        assertEquals(1_234L, bridge.epochMillis())
        bridge.onSessionEnded(session("old"))
        bridge.onSessionStarted(session("new"), session("old"))
        subscription.close()

        assertEquals(0, rum.lookups.get())
        assertEquals(3, notifications)
        assertEquals(3L, bridge.invalidationEpoch())
        assertEquals(0, rum.shutdowns)
    }

    @Test
    fun `capture uses the provider each time rather than observer cached identity`() {
        val bridge = ReplaySessionBridge()
        val rum = FakeRum()
        bridge.attach(rum)
        bridge.onSessionStarted(session("stale-observer-id"), session("old"))

        assertEquals("sdk-session-a", bridge.resolveSessionIdForUserCapture())
        rum.currentId = "sdk-session-b"
        assertEquals("sdk-session-b", bridge.resolveSessionIdForUserCapture())
        assertEquals(2, rum.lookups.get())
    }

    @Test
    fun `synchronous SDK rotation has advanced the epoch before capture resolution returns`() {
        val bridge = ReplaySessionBridge()
        val rum = FakeRum()
        bridge.attach(rum)
        val before = bridge.invalidationEpoch()
        val listenerEpochs = mutableListOf<Long>()
        bridge.subscribe { listenerEpochs += bridge.invalidationEpoch() }
        rum.beforeLookupReturns = {
            bridge.onSessionEnded(session("old"))
            bridge.onSessionStarted(session("sdk-session-a"), session("old"))
        }

        assertEquals("sdk-session-a", bridge.resolveSessionIdForUserCapture())
        assertEquals(listOf(before + 1, before + 2), listenerEpochs)
        assertEquals(before + 2, bridge.invalidationEpoch())
        assertEquals(1, rum.lookups.get())
    }

    @Test
    fun `closed subscriptions are not called and closing twice is harmless`() {
        val bridge = ReplaySessionBridge()
        var first = 0
        var second = 0
        val closed = bridge.subscribe { first++ }
        val remaining = bridge.subscribe { second++ }
        closed.close()
        closed.close()

        bridge.onSessionEnded(session("old"))
        assertEquals(0, first)
        assertEquals(1, second)
        remaining.close()
        bridge.onSessionEnded(session("old"))
        assertEquals(1, second)
    }

    @Test
    fun `closing a later subscriber during notification prevents its retained callback`() {
        val bridge = ReplaySessionBridge()
        var laterCalls = 0
        lateinit var later: AutoCloseable
        bridge.subscribe { later.close() }
        later = bridge.subscribe { laterCalls++ }

        bridge.onSessionEnded(session("old"))

        assertEquals(0, laterCalls)
    }

    @Test
    fun `listener failure does not escape into the SDK or block another listener`() {
        val bridge = ReplaySessionBridge()
        var observedEpoch = -1L
        bridge.subscribe { error("detached recorder") }
        bridge.subscribe { observedEpoch = bridge.invalidationEpoch() }

        bridge.onSessionEnded(session("old"))

        assertEquals(1L, observedEpoch)
    }

    @Test
    fun `same runtime attachment is idempotent and a different runtime is rejected`() {
        val bridge = ReplaySessionBridge()
        val rum = FakeRum()
        bridge.attach(rum)
        val attachedEpoch = bridge.invalidationEpoch()
        bridge.attach(rum)

        assertEquals(attachedEpoch, bridge.invalidationEpoch())
        assertThrows(IllegalArgumentException::class.java) { bridge.attach(FakeRum()) }
        assertEquals("sdk-session-a", bridge.resolveSessionIdForUserCapture())
        assertEquals(1, rum.lookups.get())
        assertEquals(attachedEpoch, bridge.invalidationEpoch())
    }

    @Test
    fun `SDK callback invalidates immediately on its worker thread without a session lookup`() {
        val bridge = ReplaySessionBridge()
        val rum = FakeRum()
        bridge.attach(rum)
        var observedThread: Thread? = null
        var observedEpoch = -1L
        bridge.subscribe {
            observedThread = Thread.currentThread()
            observedEpoch = bridge.invalidationEpoch()
        }
        val executor = Executors.newSingleThreadExecutor()
        try {
            val caller = executor.submit<Thread> {
                bridge.onSessionStarted(session("new"), session("old"))
                Thread.currentThread()
            }.get(5, TimeUnit.SECONDS)

            assertSame(caller, observedThread)
            assertEquals(2L, observedEpoch)
            assertEquals(2L, bridge.invalidationEpoch())
            assertEquals(0, rum.lookups.get())
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun `concurrent notifications preserve every invalidation`() {
        val bridge = ReplaySessionBridge()
        val executor = Executors.newFixedThreadPool(4)
        try {
            val tasks = (0 until 100).map {
                executor.submit { bridge.onSessionEnded(session("old")) }
            }
            tasks.forEach { it.get(5, TimeUnit.SECONDS) }
            assertEquals(100L, bridge.invalidationEpoch())
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun `empty SDK identity remains unavailable`() {
        val bridge = ReplaySessionBridge()
        val rum = FakeRum().apply { currentId = " " }
        bridge.attach(rum)

        assertNull(bridge.resolveSessionIdForUserCapture())
        assertEquals(1, rum.lookups.get())
    }

    @Test
    fun `provider failure reaches the recorder without fabricating an identity`() {
        val bridge = ReplaySessionBridge()
        val failure = IllegalStateException("SDK unavailable")
        val rum = FakeRum().apply { beforeLookupReturns = { throw failure } }
        bridge.attach(rum)

        assertSame(failure, assertThrows(IllegalStateException::class.java) {
            bridge.resolveSessionIdForUserCapture()
        })
        assertEquals(1, rum.lookups.get())
    }

    private fun session(value: String): Session = object : Session {
        override val id = value
        override val startTimestamp = 0L
    }

    private class FakeRum : OpenTelemetryRum {
        val lookups = AtomicInteger()
        var currentId = "sdk-session-a"
        var beforeLookupReturns: (() -> Unit)? = null
        var shutdowns = 0
        override val openTelemetry = OpenTelemetry.noop()
        override val sessionProvider = SessionProvider {
            lookups.incrementAndGet()
            beforeLookupReturns?.invoke()
            currentId
        }
        override val clock = object : Clock {
            override fun now(): Long = 1_234_567_890L
            override fun nanoTime(): Long = 555L
        }

        override fun emitEvent(eventName: String, body: String, attributes: Attributes) = Unit

        override fun shutdown() {
            shutdowns++
        }
    }
}

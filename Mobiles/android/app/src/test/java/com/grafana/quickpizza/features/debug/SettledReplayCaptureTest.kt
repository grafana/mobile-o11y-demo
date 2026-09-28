package com.grafana.quickpizza.features.debug

import com.grafana.faro.replay.CaptureRequestResult
import com.grafana.faro.replay.ReplayRecorder
import com.grafana.faro.replay.StartResult
import org.junit.Assert.*
import org.junit.Test

class SettledReplayCaptureTest {
    @Test fun `all audited demo screens capture while profile and config remain unsupported`() {
        val f = Fixture()
        f.policy.start()
        for (screen in listOf("Home", "Login", "About", "Debug")) {
            f.policy.screenChanged(screen)
            f.advance(500)
        }
        assertEquals(listOf("Home", "Login", "About", "Debug"), f.recorder.captures)
        for (screen in listOf("Profile", "Config", "unknown")) {
            f.policy.screenChanged(screen)
            f.advance(1_000)
        }
        assertEquals(4, f.recorder.captures.size)
    }

    @Test fun `capture requires explicit opt in then coalesces a burst of real changes`() {
        val f = Fixture()
        f.policy.changed("Home")
        f.advance(2_000)
        assertTrue(f.tasks.isEmpty())
        assertEquals(0, f.recorder.starts)
        assertEquals(StartResult.STARTED, f.policy.start())
        val original = f.tasks.last()
        f.advance(200)
        f.policy.changed("Home")
        f.advance(200)
        f.policy.changed("Home")
        original.action() // Simulate a scheduler retaining a cancelled callback.
        f.advance(499)
        assertTrue(f.recorder.captures.isEmpty())
        f.advance(1)
        assertEquals(listOf("Home"), f.recorder.captures)
        f.advance(2_000)
        assertEquals(1, f.recorder.captures.size)
    }

    @Test fun `scrolling invalidates capture and waits for scrolling to stop and settle`() {
        val f = Fixture()
        f.policy.start()
        f.advance(500)
        f.policy.scrolling("Home", true)
        assertEquals("Home", f.invalidations.last())
        f.policy.changed("Home")
        f.advance(2_000)
        assertEquals(1, f.recorder.captures.size)
        f.policy.scrolling("Home", false)
        f.advance(499)
        assertEquals(1, f.recorder.captures.size)
        f.advance(1)
        assertEquals(listOf("Home", "Home"), f.recorder.captures)
    }

    @Test fun `starting during an existing scroll waits until it stops`() {
        val f = Fixture()
        f.policy.scrolling("Home", true)
        assertTrue(f.tasks.isEmpty())
        f.policy.start()
        f.advance(2_000)
        assertTrue(f.recorder.captures.isEmpty())
        f.policy.scrolling("Home", false)
        f.advance(500)
        assertEquals(listOf("Home"), f.recorder.captures)
    }

    @Test fun `background navigation stop and restart invalidate retained capture callbacks`() {
        val f = Fixture()
        f.policy.start()
        val home = f.tasks.last()
        f.policy.foregroundChanged(false)
        home.action()
        assertNull(f.invalidations.last())
        f.advance(500)
        assertTrue(f.recorder.captures.isEmpty())
        f.policy.foregroundChanged(true)
        val resumed = f.tasks.last()
        f.policy.screenChanged("Login")
        resumed.action()
        f.advance(500)
        assertEquals(listOf("Login"), f.recorder.captures)
        f.policy.changed("Login")
        val stopped = f.tasks.last()
        f.policy.stop()
        stopped.action()
        f.policy.start()
        home.action()
        resumed.action()
        stopped.action()
        assertEquals(listOf("Login"), f.recorder.captures)
        f.advance(500)
        assertEquals(listOf("Login", "Login"), f.recorder.captures)
    }

    @Test fun `repeated start preserves original deadline and cancelled deadline cannot stop a new run`() {
        val f = Fixture(duration = 3_000)
        f.policy.start()
        val oldDeadline = f.tasks.first()
        f.advance(2_000)
        assertEquals(StartResult.ALREADY_STARTED, f.policy.start())
        assertEquals(1, f.recorder.starts)
        f.advance(1_000)
        assertFalse(f.policy.active)
        assertEquals(1, f.recorder.stops)
        assertEquals(StartResult.STARTED, f.policy.start())
        oldDeadline.action()
        assertTrue(f.policy.active)
        f.advance(3_000)
        assertFalse(f.policy.active)
    }

    @Test fun `resume after original deadline expires does not restart even if deadline callback was delayed`() {
        val f = Fixture(duration = 3_000)
        f.policy.start()
        f.policy.foregroundChanged(false)
        f.now = 4_000
        f.policy.foregroundChanged(true)
        f.policy.screenChanged("Login")
        f.policy.changed("Login")
        f.tasks.forEach { it.action() }
        assertFalse(f.policy.active)
        assertEquals(1, f.recorder.starts)
        assertTrue(f.recorder.captures.isEmpty())
    }

    @Test fun `busy retries are bounded and a later real change gets its own bounded budget`() {
        val f = Fixture(retries = 2)
        f.recorder.result = CaptureRequestResult.IN_FLIGHT
        f.policy.start()
        repeat(8) { f.advance(500) }
        assertEquals(3, f.recorder.captures.size) // Initial attempt plus two retries.
        assertEquals(1, f.recorder.starts)
        f.policy.changed("Home")
        repeat(8) { f.advance(500) }
        assertEquals(6, f.recorder.captures.size)
        assertEquals(1, f.recorder.starts)
        f.recorder.result = CaptureRequestResult.REQUESTED
        f.policy.changed("Home")
        f.advance(500)
        f.advance(2_000)
        assertEquals(7, f.recorder.captures.size)
    }

    @Test fun `a change while capture is busy replaces its retry and gets a fresh debounce`() {
        val f = Fixture(retries = 1)
        f.recorder.result = CaptureRequestResult.IN_FLIGHT
        f.policy.start()
        f.advance(500)
        val staleRetry = f.tasks.last()
        f.advance(400)
        f.policy.changed("Home")
        staleRetry.action()
        f.advance(499)
        assertEquals(1, f.recorder.captures.size)
        f.advance(1)
        f.advance(500)
        f.advance(2_000)
        assertEquals(3, f.recorder.captures.size)
        assertEquals(1, f.recorder.starts)
    }

    @Test fun `stale screen events do not invalidate or delay the current screen`() {
        val f = Fixture()
        f.policy.start()
        f.policy.screenChanged("Login")
        val invalidations = f.invalidations.toList()
        f.advance(400)
        f.policy.changed("Home")
        f.policy.scrolling("Home", true)
        assertEquals(invalidations, f.invalidations)
        f.advance(100)
        assertEquals(listOf("Login"), f.recorder.captures)
        f.policy.screenChanged("Profile")
        f.policy.changed("Profile")
        f.advance(500)
        assertEquals(listOf("Login"), f.recorder.captures)
        assertNull(f.invalidations.last())
    }

    @Test fun `terminal recorder responses stop the policy and never implicitly restart`() {
        for (result in listOf(CaptureRequestResult.LIMIT_REACHED, CaptureRequestResult.NOT_STARTED,
            CaptureRequestResult.CLOSED, CaptureRequestResult.SESSION_UNAVAILABLE)) {
            val f = Fixture()
            f.recorder.result = result
            f.policy.start()
            f.advance(500)
            assertFalse(result.name, f.policy.active)
            f.policy.changed("Home")
            f.policy.screenChanged("Login")
            f.policy.foregroundChanged(false)
            f.policy.foregroundChanged(true)
            f.advance(1_000)
            assertEquals(1, f.recorder.starts)
            assertEquals(listOf("Home"), f.recorder.captures)
        }
    }

    @Test fun `start failures leave no work and close permanently rejects start`() {
        val f = Fixture()
        f.recorder.startResult = StartResult.SDK_UNAVAILABLE
        assertEquals(StartResult.SDK_UNAVAILABLE, f.policy.start())
        assertFalse(f.policy.active)
        assertTrue(f.tasks.isEmpty())
        f.recorder.startResult = StartResult.STARTED
        f.policy.start()
        val retained = f.tasks.toList()
        f.policy.close()
        f.policy.close()
        retained.forEach { it.action() }
        assertEquals(StartResult.CLOSED, f.policy.start())
        assertTrue(f.recorder.captures.isEmpty())
        assertEquals(0, f.recorder.closes) // The host still owns the recorder.
    }

    @Test fun `inline scheduling and scheduler exceptions fail closed without recursive retries`() {
        for (throwing in listOf(false, true)) {
            val recorder = FakeRecorder()
            var schedules = 0
            val policy = SettledReplayCapture(recorder, { 0 }, { _, action ->
                schedules++
                if (throwing) error("scheduler unavailable")
                action()
                AutoCaptureCancellation { action() }
            }, {})
            policy.screenChanged("Home")
            policy.foregroundChanged(true)
            assertEquals(StartResult.SDK_UNAVAILABLE, policy.start())
            assertEquals(1, schedules)
            assertFalse(policy.active)
            assertTrue(recorder.captures.isEmpty())
        }
    }

    @Test fun `capture scheduling failure cancels the already armed run deadline`() {
        for (throwing in listOf(false, true)) {
            val recorder = FakeRecorder()
            var schedules = 0
            var deadlineCancelled = false
            val policy = SettledReplayCapture(recorder, { 0 }, { _, action ->
                schedules++
                if (schedules == 1) {
                    AutoCaptureCancellation { deadlineCancelled = true }
                } else {
                    if (throwing) error("capture scheduler unavailable")
                    action()
                    AutoCaptureCancellation {}
                }
            }, {})
            policy.screenChanged("Home")
            policy.foregroundChanged(true)
            assertEquals(StartResult.SDK_UNAVAILABLE, policy.start())
            assertEquals(2, schedules)
            assertTrue(deadlineCancelled)
            assertFalse(policy.active)
            assertTrue(recorder.captures.isEmpty())
        }
    }

    @Test fun `cancel callbacks and cancellation failures cannot revive stale work`() {
        val f = Fixture(cancelAction = true, cancelThrows = true)
        f.policy.start()
        f.policy.changed("Home")
        f.policy.foregroundChanged(false)
        f.policy.stop()
        f.tasks.forEach { it.action() }
        assertTrue(f.recorder.captures.isEmpty())
        assertFalse(f.policy.active)
    }

    @Test fun `capture and invalidation failures stop without another automatic attempt`() {
        val f = Fixture()
        f.recorder.captureThrows = true
        f.policy.start()
        f.advance(500)
        assertFalse(f.policy.active)
        f.policy.changed("Home")
        assertEquals(1, f.recorder.starts)

        val recorder = FakeRecorder()
        val policy = SettledReplayCapture(recorder, { 0 }, { _, _ -> AutoCaptureCancellation {} },
            { error("geometry unavailable") })
        policy.screenChanged("Home")
        policy.foregroundChanged(true)
        assertEquals(StartResult.SDK_UNAVAILABLE, policy.start())
        assertFalse(policy.active)
    }

    @Test fun `a stop during recorder start wins over its successful return`() {
        val f = Fixture()
        f.recorder.onStart = { f.policy.stop() }
        assertEquals(StartResult.SDK_UNAVAILABLE, f.policy.start())
        assertFalse(f.policy.active)
        assertTrue(f.tasks.isEmpty())
        assertTrue(f.recorder.captures.isEmpty())
    }

    @Test fun `reentrant start does not recurse into the recorder`() {
        val f = Fixture()
        f.recorder.onStart = { assertEquals(StartResult.SDK_UNAVAILABLE, f.policy.start()) }
        assertEquals(StartResult.STARTED, f.policy.start())
        assertEquals(1, f.recorder.starts)
    }

    @Test fun `old capture result cannot stop a reentrantly started run`() {
        val f = Fixture()
        f.recorder.result = CaptureRequestResult.LIMIT_REACHED
        f.recorder.onCapture = {
            f.recorder.onCapture = null
            f.policy.stop()
            assertEquals(StartResult.STARTED, f.policy.start())
        }
        f.policy.start()
        f.advance(500)
        assertTrue(f.policy.active)
        assertEquals(2, f.recorder.starts)
        f.recorder.result = CaptureRequestResult.REQUESTED
        f.advance(500)
        assertEquals(listOf("Home", "Home"), f.recorder.captures)
    }

    @Test fun `a reentrant state change keeps its capture instead of an old terminal result`() {
        val f = Fixture()
        f.recorder.result = CaptureRequestResult.NOT_STARTED
        f.recorder.onCapture = {
            f.recorder.onCapture = null
            f.policy.screenChanged("Login")
        }
        f.policy.start()
        f.advance(500)
        assertTrue(f.policy.active)
        f.recorder.result = CaptureRequestResult.REQUESTED
        f.advance(500)
        assertEquals(listOf("Home", "Login"), f.recorder.captures)
        assertEquals(1, f.recorder.starts)
    }

    private class Fixture(
        duration: Long = 120_000,
        retries: Int = 10,
        cancelAction: Boolean = false,
        cancelThrows: Boolean = false,
    ) {
        var now = 0L
        val recorder = FakeRecorder()
        val invalidations = mutableListOf<String?>()
        val tasks = mutableListOf<Scheduled>()
        val policy = SettledReplayCapture(recorder, { now }, { delay, action ->
            val task = Scheduled(now + delay, action)
            tasks += task
            AutoCaptureCancellation {
                task.cancelled = true
                if (cancelAction) action()
                if (cancelThrows) error("cancel failed")
            }
        }, { invalidations += it }, maxDurationMillis = duration, maxBusyRetries = retries)

        init {
            policy.screenChanged("Home")
            policy.foregroundChanged(true)
        }

        fun advance(delta: Long) {
            now += delta
            while (true) {
                val next = tasks.filter { !it.ran && !it.cancelled && it.at <= now }.minByOrNull { it.at } ?: break
                next.ran = true
                next.action()
            }
        }
    }

    private class Scheduled(val at: Long, val action: () -> Unit) {
        var cancelled = false
        var ran = false
    }

    private class FakeRecorder : ReplayRecorder {
        var starts = 0
        var stops = 0
        var closes = 0
        var captureThrows = false
        var onStart: (() -> Unit)? = null
        var onCapture: (() -> Unit)? = null
        var startResult = StartResult.STARTED
        var result = CaptureRequestResult.REQUESTED
        val captures = mutableListOf<String>()
        override fun start(): StartResult { starts++; onStart?.invoke(); return startResult }
        override fun stop() { stops++ }
        override fun close() { closes++ }
        override fun capture(screenName: String): CaptureRequestResult {
            if (captureThrows) error("capture unavailable")
            captures += screenName
            onCapture?.invoke()
            return result
        }
    }
}

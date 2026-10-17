package com.grafana.quickpizza.features.debug

import com.grafana.faro.replay.CaptureRequestResult
import com.grafana.faro.replay.ReplayRecorder
import com.grafana.faro.replay.StartResult

internal fun interface AutoCaptureCancellation {
    fun cancel()
}

/**
 * Main-thread demo policy: explicit start, then capture registered screens after changes settle.
 * The host supplies a monotonic clock and asynchronous scheduler. No UI text, pixels, or SDK session
 * state is retained here. The recorder remains owned by the host; close stops this policy only.
 */
internal class SettledReplayCapture(
    private val recorder: ReplayRecorder,
    private val nowMillis: () -> Long,
    private val schedule: (Long, () -> Unit) -> AutoCaptureCancellation,
    private val invalidateCapture: (String?) -> Unit,
    private val settleMillis: Long = 500,
    private val maxDurationMillis: Long = 120_000,
    private val maxBusyRetries: Int = 10,
) : AutoCloseable {
    var active: Boolean = false
        private set

    private var closed = false
    private var starting = false
    private var foreground = false
    private var screen: String? = null
    private var isScrolling = false
    private var deadline = 0L
    private var run = 0L
    private var change = 0L
    private var retries = 0
    private var captureTask: Task? = null
    private var deadlineTask: Task? = null

    init {
        require(settleMillis > 0 && maxDurationMillis > 0 && maxBusyRetries >= 0)
    }

    fun start(): StartResult {
        if (closed) return StartResult.CLOSED
        if (running()) return StartResult.ALREADY_STARTED
        if (starting) return StartResult.SDK_UNAVAILABLE
        val now = readClock() ?: return StartResult.SDK_UNAVAILABLE
        if (now > Long.MAX_VALUE - maxDurationMillis) return StartResult.SDK_UNAVAILABLE
        val previousRun = run
        starting = true
        val result = try {
            recorder.start()
        } catch (_: Exception) {
            stop()
            return StartResult.SDK_UNAVAILABLE
        } finally {
            starting = false
        }
        if (closed) return StartResult.CLOSED
        if (run != previousRun) return StartResult.SDK_UNAVAILABLE
        if (result != StartResult.STARTED && result != StartResult.ALREADY_STARTED) return result
        active = true
        run++
        deadline = now + maxDurationMillis
        retries = 0
        armDeadline()
        if (active) refresh()
        return if (active) result else StartResult.SDK_UNAVAILABLE
    }

    fun stop() {
        active = false
        run++
        cancelCapture()
        val oldDeadline = deadlineTask
        deadlineTask = null
        cancel(oldDeadline)
        retries = 0
        try { recorder.stop() } catch (_: Exception) { /* State is already invalidated. */ }
    }

    override fun close() {
        if (closed) return
        closed = true
        stop()
    }

    fun screenChanged(name: String?) {
        val supported = name?.takeIf { it in setOf("Login", "Home", "About", "Debug") }
        if (screen == supported) return
        screen = supported
        isScrolling = false
        if (running()) refresh()
    }

    fun foregroundChanged(value: Boolean) {
        if (foreground == value) {
            running()
            return
        }
        foreground = value
        if (running()) refresh()
    }

    fun changed(screenName: String) {
        if (screen != screenName || !running()) return
        refresh()
    }

    fun scrolling(screenName: String, isScrolling: Boolean) {
        if (screen != screenName || this.isScrolling == isScrolling) return
        this.isScrolling = isScrolling
        if (running()) refresh()
    }

    private fun refresh() {
        cancelCapture()
        retries = 0
        val currentRun = run
        val currentChange = change
        try {
            invalidateCapture(if (foreground) screen else null)
        } catch (_: Exception) {
            if (run == currentRun && change == currentChange) stop()
            return
        }
        if (run != currentRun || change != currentChange) return
        if (eligible()) armCapture()
    }

    private fun eligible(): Boolean = active && foreground && screen != null && !isScrolling

    private fun armCapture() {
        val now = readClock() ?: return
        if (now >= deadline) {
            stop()
            return
        }
        // The deadline owns expiry; do not schedule a capture at or beyond it.
        if (settleMillis >= deadline - now) return
        val task = Task(run)
        captureTask = task
        arm(task, settleMillis) {
            if (captureTask !== task) return@arm
            captureTask = null
            if (!running() || !eligible()) return@arm
            val currentChange = change
            val result = try {
                recorder.capture(checkNotNull(screen))
            } catch (_: Exception) {
                if (run == task.run && change == currentChange) stop()
                return@arm
            }
            if (run != task.run || change != currentChange || !running()) return@arm
            when (result) {
                CaptureRequestResult.IN_FLIGHT -> if (retries < maxBusyRetries) {
                    retries++
                    armCapture()
                }
                CaptureRequestResult.NOT_STARTED, CaptureRequestResult.LIMIT_REACHED,
                CaptureRequestResult.CLOSED, CaptureRequestResult.SESSION_UNAVAILABLE -> stop()
                else -> Unit // A successful request or an ineligible window needs a new change.
            }
        }
    }

    private fun armDeadline() {
        val now = readClock() ?: return
        if (now >= deadline) {
            stop()
            return
        }
        val task = Task(run)
        deadlineTask = task
        arm(task, deadline - now) {
            if (deadlineTask !== task) return@arm
            deadlineTask = null
            // Even a broken scheduler firing early must not extend the original run.
            stop()
        }
    }

    private fun arm(task: Task, delay: Long, action: () -> Unit) {
        var scheduling = true
        var ranInline = false
        val cancellation = try {
            schedule(delay) {
                if (scheduling) {
                    ranInline = true
                } else if (active && run == task.run && !task.cancelled) {
                    action()
                }
            }
        } catch (_: Exception) {
            scheduling = false
            if (task.run == run && !task.cancelled) stop()
            return
        }
        scheduling = false
        task.cancellation = cancellation
        if (ranInline && task.run == run && !task.cancelled) {
            stop()
        } else if (task.cancelled || !active || task.run != run) {
            cancel(task)
        }
    }

    private fun running(): Boolean {
        if (!active || closed) return false
        val now = readClock() ?: return false
        if (now >= deadline) {
            stop()
            return false
        }
        return true
    }

    private fun readClock(): Long? = try {
        nowMillis().also { check(it >= 0) }
    } catch (_: Exception) {
        stop()
        null
    }

    private fun cancelCapture() {
        change++
        val task = captureTask
        captureTask = null
        cancel(task)
    }

    private fun cancel(task: Task?) {
        if (task == null) return
        task.cancelled = true
        val cancellation = task.cancellation
        task.cancellation = null
        try { cancellation?.cancel() } catch (_: Exception) { /* Retained callbacks stay invalid. */ }
    }

    private class Task(val run: Long) {
        var cancellation: AutoCaptureCancellation? = null
        var cancelled = false
    }
}

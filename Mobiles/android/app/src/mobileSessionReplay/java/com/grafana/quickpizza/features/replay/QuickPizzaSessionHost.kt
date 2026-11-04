package com.grafana.quickpizza.features.replay

import com.grafana.faro.replay.FaroReplaySessionHost
import com.grafana.faro.replay.FaroReplaySessionSnapshot
import io.opentelemetry.android.OpenTelemetryRum
import io.opentelemetry.android.session.Session
import io.opentelemetry.android.session.SessionObserver
import io.opentelemetry.sdk.common.Clock
import java.time.Duration
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference

/**
 * Passive session bridge for QuickPizza's OpenTelemetry Android runtime.
 *
 * Identity comes only from [SessionObserver]. This host does not call
 * [io.opentelemetry.android.session.SessionProvider.getSessionId], which refreshes
 * inactivity and can rotate the session. QuickPizza does not install a session ratio
 * sampler, so a live observer session is treated as RUM-sampled. Max lifetime matches
 * the SDK default of 4 hours, which this app does not override.
 *
 * TODO(faro-replay-otel-android): hackathon stand-in. Move this class into
 * `com.grafana.faro:faro-replay-otel-android`, published against the tested
 * OpenTelemetry Android version. Client apps then install that artifact and
 * `com.grafana.faro:faro-android-replay`, and delete this copy.
 */
internal class QuickPizzaSessionHost : FaroReplaySessionHost, SessionObserver {
    private val state = AtomicReference(State(sessionId = null, startTimestampNanos = 0L, epoch = 0L))
    private val clock = AtomicReference<Clock?>(null)
    private val listeners = CopyOnWriteArrayList<() -> Unit>()

    fun attach(rum: OpenTelemetryRum) {
        clock.set(rum.clock)
    }

    override fun onSessionStarted(newSession: Session, previousSession: Session) {
        state.updateAndGet { current ->
            State(
                sessionId = newSession.id.takeIf { it.isNotBlank() },
                startTimestampNanos = newSession.startTimestamp,
                epoch = current.epoch + 1,
            )
        }
        notifyListeners()
    }

    override fun onSessionEnded(session: Session) {
        val before = state.get()
        val after = state.updateAndGet { current ->
            if (current.sessionId == session.id) {
                State(sessionId = null, startTimestampNanos = 0L, epoch = current.epoch + 1)
            } else {
                current
            }
        }
        if (after.epoch != before.epoch) notifyListeners()
    }

    override fun currentSessionSnapshot(): FaroReplaySessionSnapshot {
        val current = state.get()
        val id = current.sessionId?.takeIf { !isExpired(current) }
        return FaroReplaySessionSnapshot(
            sessionId = id,
            isRumSampled = id != null,
            invalidationEpoch = current.epoch,
        )
    }

    override fun subscribe(onChanged: () -> Unit): AutoCloseable {
        listeners.add(onChanged)
        return AutoCloseable { listeners.remove(onChanged) }
    }

    override fun captureTimeMillis(): Long {
        val nanos = clock.get()?.now() ?: return System.currentTimeMillis()
        return nanos / NANOS_PER_MILLI
    }

    private fun isExpired(current: State): Boolean {
        val now = clock.get()?.now() ?: return false
        return now - current.startTimestampNanos >= MAX_LIFETIME_NANOS
    }

    private fun notifyListeners() {
        listeners.forEach { listener -> listener() }
    }

    private data class State(
        val sessionId: String?,
        val startTimestampNanos: Long,
        val epoch: Long,
    )

    private companion object {
        const val NANOS_PER_MILLI = 1_000_000L
        val MAX_LIFETIME_NANOS: Long = Duration.ofHours(4).toNanos()
    }
}

package com.grafana.quickpizza.features.debug

import com.grafana.faro.replay.ReplaySessionSource
import io.opentelemetry.android.OpenTelemetryRum
import io.opentelemetry.android.session.Session
import io.opentelemetry.android.session.SessionObserver
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * Process-owned observer registered when the host initializes its existing RUM SDK.
 *
 * The 1.7.0 session getter records activity, so only the recorder's explicit user capture calls it.
 * Callbacks invalidate work immediately on the SDK caller's thread; the recorder owns dispatch.
 * The SDK cannot unregister an observer, so recorder subscriptions detach from this bridge instead.
 */
internal class ReplaySessionBridge : ReplaySessionSource, SessionObserver {
    private val runtime = AtomicReference<OpenTelemetryRum?>()
    private val epoch = AtomicLong()
    private val subscribers = CopyOnWriteArrayList<Subscription>()

    /** Attach once after successful host initialization. This never initializes or shuts down RUM. */
    fun attach(rum: OpenTelemetryRum) {
        if (runtime.compareAndSet(null, rum)) {
            invalidate()
        } else {
            require(runtime.get() === rum) { "Replay is already attached to another RUM runtime" }
        }
    }

    override fun resolveSessionIdForUserCapture(): String? =
        runtime.get()?.sessionProvider?.getSessionId()?.takeIf { it.isNotBlank() }

    override fun invalidationEpoch(): Long = epoch.get()

    /** Epoch time from the same SDK clock as the correlated telemetry, converted from nanoseconds. */
    fun epochMillis(): Long? = runtime.get()?.clock?.now()?.div(1_000_000L)

    override fun subscribe(listener: () -> Unit): AutoCloseable {
        val subscription = Subscription(listener)
        subscribers.add(subscription)
        return AutoCloseable {
            subscription.close()
            subscribers.remove(subscription)
        }
    }

    override fun onSessionEnded(session: Session) = invalidate()

    override fun onSessionStarted(newSession: Session, previousSession: Session) = invalidate()

    private fun invalidate() {
        // Advance before notification; a concurrent completion sees the invalidation even if the
        // main thread has not processed its posted listener callback yet. Never cache session IDs.
        epoch.incrementAndGet()
        subscribers.forEach { it.notifyChanged() }
    }

    private class Subscription(listener: () -> Unit) {
        private val callback = AtomicReference<(() -> Unit)?>(listener)

        fun close() {
            callback.set(null)
        }

        fun notifyChanged() {
            try {
                callback.get()?.invoke()
            } catch (_: Exception) {
                // A detached or failed recorder must not break the SDK's synchronous notifications
                // or prevent other recorders from seeing the change. Do not log session contents.
            }
        }
    }
}

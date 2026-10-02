package com.grafana.quickpizza.features.debug

import android.app.Application
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.grafana.faro.replay.AndroidReplayRecorder
import com.grafana.faro.replay.CaptureRequestResult
import com.grafana.faro.replay.MaskOptions
import com.grafana.faro.replay.ReplayConfig
import com.grafana.faro.replay.ReplayUploadConfig
import com.grafana.faro.replay.StartResult
import com.grafana.quickpizza.BuildConfig
import com.grafana.quickpizza.core.config.AppConfig
import com.grafana.quickpizza.core.config.RuntimeConfig
import com.grafana.quickpizza.core.config.replayEndpoint
import com.grafana.quickpizza.core.o11y.OTelService
import com.grafana.quickpizza.core.o11y.OtelLogger
import io.opentelemetry.api.common.AttributeKey
import io.opentelemetry.api.trace.StatusCode
import io.opentelemetry.sdk.trace.ReadableSpan

/** Explicit debug journey using the app's one existing RUM SDK and the standalone recorder. */
internal object ReplayJourney {
    val geometry = ReplayJourneyGeometry { name -> changed(name) }
    var recorder: AndroidReplayRecorder? = null
        private set
    private var telemetry: OTelService? = null
    private var automatic: SettledReplayCapture? = null
    var automaticActive by mutableStateOf(false)
        private set
    var screen: String? = null
        private set
    var errorVisible = false
        private set
    var lastError: ReplayDemoError? = null
        private set

    fun install(application: Application, otel: OTelService, config: AppConfig, runtime: RuntimeConfig) {
        if (!BuildConfig.DEBUG || otel.openTelemetryRum == null) return
        val endpoint = runtime.replayEndpoint() ?: return
        check(recorder == null) { "Replay is process-owned; install only once" }
        val headers = runtime.otlpAuthHeader?.let { mapOf("Authorization" to it) }.orEmpty()
        val bridge = otel.replaySession
        recorder = AndroidReplayRecorder.create(
            application, bridge, geometry,
            ReplayUploadConfig(
                ingestEndpoint = endpoint.ingestEndpoint,
                appName = OTelService.SERVICE_NAME,
                appVersion = config.appVersion,
                headers = headers,
                allowLoopbackHttp = endpoint.allowLoopbackHttp,
            ),
            ReplayConfig(masks = MaskOptions(maskAllText = false, maskAllInputs = true, blockAllMedia = false), useMobileVideoClips = true),
            epochMillis = { checkNotNull(bridge.epochMillis()) },
        )
        val handler = Handler(Looper.getMainLooper())
        automatic = SettledReplayCapture(
            recorder = checkNotNull(recorder),
            nowMillis = SystemClock::elapsedRealtime,
            schedule = { delay, action ->
                val task = Runnable {
                    action()
                    automaticActive = automatic?.active == true
                }
                check(handler.postDelayed(task, delay))
                AutoCaptureCancellation { handler.removeCallbacks(task) }
            },
            invalidateCapture = { name ->
                geometry.invalidate()
                recorder?.updateScreen(name)
            },
        )
        telemetry = otel
    }

    fun screenChanged(name: String?) {
        if (screen == name) return
        screen = name
        geometry.invalidate()
        recorder?.updateScreen(name)
        automatic?.screenChanged(name)
    }

    fun startAutomatic(): StartResult {
        // Manual captures are a separate explicit run; do not inherit their nearly expired limit.
        if (automatic?.active != true) recorder?.stop()
        val result = automatic?.start() ?: StartResult.SDK_UNAVAILABLE
        automaticActive = automatic?.active == true
        return result
    }

    fun stop() {
        automatic?.stop()
        recorder?.stop()
        automaticActive = false
    }

    fun foregroundChanged(foreground: Boolean) {
        automatic?.foregroundChanged(foreground)
        automaticActive = automatic?.active == true
    }

    fun changed(name: String) {
        automatic?.changed(name)
        automaticActive = automatic?.active == true
    }

    fun scrolling(name: String, moving: Boolean) {
        automatic?.scrolling(name, moving)
        automaticActive = automatic?.active == true
    }

    fun capture(name: String): CaptureRequestResult {
        val active = recorder ?: return CaptureRequestResult.SESSION_UNAVAILABLE
        if (!automaticActive && active.start() !in setOf(StartResult.STARTED, StartResult.ALREADY_STARTED)) {
            return CaptureRequestResult.SESSION_UNAVAILABLE
        }
        if (screen != name) return CaptureRequestResult.UNSUPPORTED_SCREEN
        return active.capture(name)
    }

    /** A deterministic handled error, deliberately independent of a live pizza backend. */
    fun emitDemoError(): String? {
        val otel = telemetry ?: return null
        val span = otel.getTracer().spanBuilder("replay.demo.checkout").startSpan()
        try {
            // Read the session already attributed to this real SDK span. Do not refresh the SDK's
            // session getter to label an error or retain a possibly stale observer-cached ID.
            val sessionId = (span as? ReadableSpan)?.getAttribute(AttributeKey.stringKey("session.id"))
            val identity = ReplayDemoError(span.spanContext.traceId, span.spanContext.spanId,
                sessionId, otel.replaySession.epochMillis(), span.spanContext.isSampled)
            span.makeCurrent().use {
                val error = IllegalStateException("Replay demo: checkout unavailable")
                span.setAttribute("replay.demo.journey", "login-home-checkout")
                span.recordException(error)
                span.setStatus(StatusCode.ERROR, "Replay demo checkout unavailable")
                val attributes = buildMap {
                    put("replay.demo.journey", "login-home-checkout")
                    // Keep the handled error attached to its span even if SDK expiry races emit.
                    sessionId?.takeIf { it.isNotBlank() }?.let { put("session.id", it) }
                }
                OtelLogger(otel.getLoggerProvider()).exception(
                    "Replay demo: checkout unavailable", error, attributes,
                )
            }
            lastError = identity
            errorVisible = true
            return identity.traceId
        } finally {
            span.end()
        }
    }
}

/** Synthetic debug evidence only; IDs come from the emitted SDK span, never from generated values. */
internal data class ReplayDemoError(
    val traceId: String,
    val spanId: String,
    val sessionId: String?,
    val triggeredAtEpochMillis: Long?,
    val sampled: Boolean,
)

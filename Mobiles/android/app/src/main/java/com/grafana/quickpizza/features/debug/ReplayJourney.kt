package com.grafana.quickpizza.features.debug

import android.app.Application
import com.grafana.faro.replay.AndroidReplayRecorder
import com.grafana.faro.replay.CaptureRequestResult
import com.grafana.faro.replay.MaskOptions
import com.grafana.faro.replay.ReplayConfig
import com.grafana.faro.replay.ReplayUploadConfig
import com.grafana.faro.replay.StartResult
import com.grafana.quickpizza.BuildConfig
import com.grafana.quickpizza.core.config.AppConfig
import com.grafana.quickpizza.core.config.RuntimeConfig
import com.grafana.quickpizza.core.o11y.OTelService
import com.grafana.quickpizza.core.o11y.OtelLogger
import io.opentelemetry.api.common.AttributeKey
import io.opentelemetry.api.trace.StatusCode
import io.opentelemetry.sdk.trace.ReadableSpan
import java.net.URI

/** Explicit debug journey using the app's one existing RUM SDK and the standalone recorder. */
internal object ReplayJourney {
    val geometry = ReplayJourneyGeometry()
    var recorder: AndroidReplayRecorder? = null
        private set
    private var telemetry: OTelService? = null
    var screen: String? = null
        private set
    var errorVisible = false
        private set
    var lastError: ReplayDemoError? = null
        private set

    fun install(application: Application, otel: OTelService, config: AppConfig, runtime: RuntimeConfig) {
        if (!BuildConfig.DEBUG || config.otlpEndpoint.isBlank() || otel.openTelemetryRum == null) return
        check(recorder == null) { "Replay is process-owned; install only once" }
        val local = URI(config.otlpEndpoint).host in setOf("localhost", "127.0.0.1", "10.0.2.2")
        val headers = runtime.otlpAuthHeader?.let { mapOf("Authorization" to it) }.orEmpty()
        val bridge = otel.replaySession
        recorder = AndroidReplayRecorder.create(
            application, bridge, geometry,
            ReplayUploadConfig(
                ingestEndpoint = config.otlpEndpoint,
                appName = OTelService.SERVICE_NAME,
                appVersion = config.appVersion,
                headers = headers,
                allowLoopbackHttp = local,
            ),
            ReplayConfig(masks = MaskOptions(maskAllText = false), useMobileVideoClips = true),
            epochMillis = { checkNotNull(bridge.epochMillis()) },
        )
        telemetry = otel
    }

    fun screenChanged(name: String?) {
        if (screen == name) return
        screen = name
        geometry.invalidate()
        recorder?.updateScreen(name)
    }

    fun capture(name: String): CaptureRequestResult {
        val active = recorder ?: return CaptureRequestResult.SESSION_UNAVAILABLE
        if (active.start() !in setOf(StartResult.STARTED, StartResult.ALREADY_STARTED)) {
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

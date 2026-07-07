package com.grafana.quickpizza.core.o11y

import android.app.Application
import android.util.Log
import com.grafana.quickpizza.core.config.AppConfig
import com.grafana.quickpizza.core.config.RuntimeConfigHolder
import io.opentelemetry.android.OpenTelemetryRum
import io.opentelemetry.android.agent.OpenTelemetryRumInitializer
import io.opentelemetry.api.OpenTelemetry
import io.opentelemetry.api.common.AttributeKey
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class OTelService @Inject constructor(
    private val application: Application,
    private val appConfig: AppConfig,
    private val runtimeConfig: RuntimeConfigHolder,
) {
    private var rum: OpenTelemetryRum? = null

    val openTelemetry: OpenTelemetry
        get() = rum?.openTelemetry ?: OpenTelemetry.noop()

    fun initialize() {
        val snapshot = runtimeConfig.current
        val endpoint = snapshot.otlpEndpoint
        val authHeader = snapshot.otlpAuthHeader
        val diskBufferingEnabled = snapshot.diskBufferingEnabled

        if (endpoint.isEmpty()) {
            Log.w(TAG, "OTLP endpoint not configured — running with noop telemetry")
            return
        }

        rum = runCatching {
            OpenTelemetryRumInitializer.initialize(application) {
                httpExport {
                    baseUrl = endpoint
                    if (authHeader != null) {
                        baseHeaders = mapOf("Authorization" to authHeader)
                    }
                }
                // SDK default is `enabled = true`. Setting it explicitly keeps
                // intent visible and lets the debug toggle flip it off for low-latency demos.
                diskBuffering {
                    enabled(diskBufferingEnabled)
                }
                resource {
                    // Logical service name for traces/dashboards (not the package name).
                    // This groups all Android app telemetry together, similar to how
                    // the app name appears in Frontend Observability.
                    put(AttributeKey.stringKey("service.name"), SERVICE_NAME)
                    put(AttributeKey.stringKey("service.namespace"), "quickpizza")
                    // App version - matches the version displayed to users.
                    put(AttributeKey.stringKey("service.version"), appConfig.appVersion)
                    // Encoded build identity — maps to meta.app.bundleId for Android symbol retrace.
                    put(AttributeKey.stringKey("faro.app.bundleId"), appConfig.symbolsBundleId)
                }
            }
        }.onFailure { Log.e(TAG, "OTelService initialization failed", it) }.getOrNull()

        if (rum != null) {
            Log.i(
                TAG,
                "OTelService initialized, exporting to $endpoint " +
                    "(diskBuffering=$diskBufferingEnabled)",
            )
        }
    }

    fun getTracer(instrumentationScope: String = INSTRUMENTATION_SCOPE) =
        openTelemetry.getTracer(instrumentationScope)

    fun getLoggerProvider() = openTelemetry.logsBridge

    companion object {
        private const val TAG = "OTelService"
        const val SERVICE_NAME = "quickpizza-android"
        const val INSTRUMENTATION_SCOPE = "com.grafana.quickpizza"
    }
}

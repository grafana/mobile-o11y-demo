package com.grafana.quickpizza.core.config

import kotlinx.coroutines.runBlocking
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Immutable snapshot of the URLs and credentials the app was bootstrapped with.
 *
 * This is intentionally *not* reactive: these are the values [OTelService]
 * initialized with and that [ApiClient] is using. Changing a saved override in
 * [DebugSettings] will NOT change these values — the user must restart the app
 * for the override to take effect.
 *
 * Why: keeping backend + collector + auth stable per session makes correlated
 * traces/logs/metrics much easier to reason about when demoing.
 */
data class RuntimeConfig(
    val backendBaseUrl: String,
    val otlpEndpoint: String,
    val otlpInstanceId: String,
    val otlpApiKey: String,
    val otlpAuthHeader: String?,
)

/**
 * Resolves and holds the [RuntimeConfig] snapshot for the lifetime of the
 * process. Built lazily on first access (which happens during
 * [com.grafana.quickpizza.QuickPizzaApp.onCreate]).
 */
@Singleton
class RuntimeConfigHolder @Inject constructor(
    private val appConfig: AppConfig,
    private val debugSettings: DebugSettingsRepository,
) {
    val current: RuntimeConfig by lazy {
        // Read overrides synchronously at bootstrap. DataStore is async by
        // design but the alternative — making OTelService.initialize() suspend —
        // would require restructuring Application.onCreate. A one-shot blocking
        // read at bootstrap is the conventional escape hatch.
        val saved = runBlocking { debugSettings.snapshot() }
        val instanceId = saved.otlpInstanceIdOverride ?: appConfig.otlpInstanceId
        val apiKey = saved.otlpApiKeyOverride ?: appConfig.otlpApiKey
        RuntimeConfig(
            backendBaseUrl = saved.backendUrlOverride ?: appConfig.baseUrl,
            otlpEndpoint = saved.otlpEndpointOverride ?: appConfig.otlpEndpoint,
            otlpInstanceId = instanceId,
            otlpApiKey = apiKey,
            otlpAuthHeader = buildOtlpAuthHeader(instanceId, apiKey),
        )
    }
}

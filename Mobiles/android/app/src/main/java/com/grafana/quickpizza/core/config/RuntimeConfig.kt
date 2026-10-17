package com.grafana.quickpizza.core.config

import kotlinx.coroutines.runBlocking
import java.net.URI
import java.util.Locale
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
    /**
     * Whether the OTel-Android SDK was initialized with on-device disk buffering.
     * Default `true` matches SDK behaviour (writes to disk first, ~30–45s latency).
     * `false` makes the SDK export over OTLP directly (~1–6s latency) — controlled
     * by the `Disable disk buffering` debug toggle.
     */
    val diskBufferingEnabled: Boolean,
)

/** Validated replay destination from the same resolved configuration used by the OTel SDK. */
internal class ReplayEndpoint(val ingestEndpoint: String, val allowLoopbackHttp: Boolean) {
    override fun toString(): String = "ReplayEndpoint(ingestEndpoint=<redacted>)"
}

/** Optional replay must not crash startup when the configured telemetry URL is unsupported. */
internal fun RuntimeConfig.replayEndpoint(): ReplayEndpoint? {
    val uri = runCatching { URI(otlpEndpoint) }.getOrNull() ?: return null
    val scheme = uri.scheme?.lowercase(Locale.ROOT)
    val host = uri.host?.lowercase(Locale.ROOT)
    val local = host in setOf("localhost", "127.0.0.1", "10.0.2.2")
    if (uri.isOpaque || host.isNullOrBlank() || uri.userInfo != null || uri.fragment != null) return null
    if (uri.port != -1 && uri.port !in 1..65535) return null
    if (scheme != "https" && !(scheme == "http" && local)) return null
    val path = uri.path?.lowercase(Locale.ROOT).orEmpty()
    if (!path.contains("/otlp") && !path.contains("/collect")) return null
    return ReplayEndpoint(otlpEndpoint, local)
}

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
        val otlpEndpoint = saved.otlpEndpointOverride ?: appConfig.otlpEndpoint
        RuntimeConfig(
            backendBaseUrl = saved.backendUrlOverride ?: appConfig.baseUrl,
            otlpEndpoint = otlpEndpoint,
            otlpInstanceId = instanceId,
            otlpApiKey = apiKey,
            otlpAuthHeader = buildOtlpAuthHeader(instanceId, apiKey),
            diskBufferingEnabled = !saved.disableDiskBuffering,
        )
    }
}

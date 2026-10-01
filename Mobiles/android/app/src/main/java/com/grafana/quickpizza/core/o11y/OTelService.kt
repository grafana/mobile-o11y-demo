package com.grafana.quickpizza.core.o11y

import android.app.Application
import android.os.Looper
import android.util.Log
import androidx.navigation.NavController
import com.grafana.faro.replay.AndroidProcessHost
import com.grafana.faro.replay.FaroReplay
import com.grafana.faro.replay.FaroReplayInstallation
import com.grafana.faro.replay.FaroReplayOptions
import com.grafana.faro.replay.MaskOptions
import com.grafana.opentelemetry.android.ExperimentalGrafanaOtelApi
import com.grafana.opentelemetry.android.GrafanaOtel
import com.grafana.opentelemetry.android.GrafanaOtelConfiguration
import com.grafana.quickpizza.core.config.AppConfig
import com.grafana.quickpizza.core.config.RuntimeConfigHolder
import com.grafana.quickpizza.features.replay.QuickPizzaNavHost
import com.grafana.quickpizza.features.replay.QuickPizzaSessionHost
import com.grafana.quickpizza.nativecrash.NativeExitCrashReporter
import io.opentelemetry.android.OpenTelemetryRum
import io.opentelemetry.api.OpenTelemetry
import io.opentelemetry.api.common.AttributeKey
import io.opentelemetry.api.common.Attributes
import io.opentelemetry.sdk.logs.SdkLoggerProvider
import io.opentelemetry.sdk.trace.SdkTracerProvider
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class OTelService @Inject constructor(
    private val application: Application,
    private val appConfig: AppConfig,
    private val runtimeConfig: RuntimeConfigHolder,
) {
    @Volatile
    private var rum: OpenTelemetryRum? = null

    private val replaySessionHost = QuickPizzaSessionHost()
    private val replayNavigationHost = QuickPizzaNavHost()
    private var processHost: AndroidProcessHost? = null
    private var replayInstallation: FaroReplayInstallation? = null

    val openTelemetry: OpenTelemetry
        get() = rum?.openTelemetry ?: OpenTelemetry.noop()

    /**
     * The RUM runtime, or `null` until [initialize] succeeds.
     *
     * Instrumentations that are wired up by the app rather than auto-discovered — currently
     * `compose-navigation` — take the runtime itself, not just its [OpenTelemetry]. There is no
     * noop [OpenTelemetryRum] to fall back on, so callers have to handle the unconfigured case.
     */
    val openTelemetryRum: OpenTelemetryRum?
        get() = rum

    /**
     * Installs replay once the activity has a [NavController]. Safe to call again after
     * rotation: install stays once per process and the navigation host rebinds.
     *
     * The app calls [FaroReplay.install]. The library calls its controller `onInstall`.
     *
     * TODO(faro-replay-otel-android): replace [replaySessionHost] with the class from
     * `com.grafana.faro:faro-replay-otel-android` and depend on that artifact plus
     * `com.grafana.faro:faro-android-replay`. [replayNavigationHost] stays in this app.
     */
    fun installReplay(navController: NavController) {
        check(Looper.myLooper() == Looper.getMainLooper()) {
            "FaroReplay.install requires the main thread"
        }
        replayNavigationHost.bind(navController)
        if (replayInstallation != null || rum == null) return

        val snapshot = runtimeConfig.current
        replayInstallation = FaroReplay.install(
            processHost = processHost ?: AndroidProcessHost.create(application).also { processHost = it },
            options = FaroReplayOptions(
                ingestUrl = snapshot.otlpEndpoint,
                headers = snapshot.otlpAuthHeader?.let { mapOf("Authorization" to it) }.orEmpty(),
                appName = SERVICE_NAME,
                appVersion = appConfig.appVersion,
                maskOptions = MaskOptions(
                    maskAllText = false,
                    maskAllInputs = true,
                    blockAllMedia = false,
                ),
                replaySamplingRate = 1.0f,
                allowLoopbackHttp = allowsLoopback(snapshot.otlpEndpoint),
            ),
            sessionHost = replaySessionHost,
            navigationHost = replayNavigationHost,
        )
    }

    @Synchronized
    fun initialize() {
        if (rum != null) {
            Log.i(TAG, "OTelService already initialized; keeping the existing process runtime")
            return
        }

        val snapshot = runtimeConfig.current
        val endpoint = snapshot.otlpEndpoint
        val authHeader = snapshot.otlpAuthHeader
        val diskBufferingEnabled = snapshot.diskBufferingEnabled

        if (endpoint.isEmpty()) {
            Log.w(TAG, "OTLP endpoint not configured — running with noop telemetry")
            return
        }

        rum = runCatching {
            @OptIn(ExperimentalGrafanaOtelApi::class)
            GrafanaOtel.initialize(
                application = application,
                configuration = GrafanaOtelConfiguration(
                    otlpEndpoint = endpoint,
                    headers = authHeader?.let { mapOf("Authorization" to it) }.orEmpty(),
                    serviceName = SERVICE_NAME,
                    serviceNamespace = "quickpizza",
                    serviceVersion = appConfig.appVersion,
                    resourceAttributes = Attributes.builder()
                        // Encoded build identity maps to meta.app.bundleId for Android retrace.
                        .put(AttributeKey.stringKey("faro.app.bundleId"), appConfig.symbolsBundleId)
                        .build(),
                    diskBufferingEnabled = diskBufferingEnabled,
                    // Pin the pre-1.5.0 convention names (device.crash, screen.name, ...) until
                    // the existing consumer accepts the latest experimental conventions.
                    useLatestExperimentalSemanticConventions = false,
                ),
            ) {
                // Register before the first session starts. A later observer misses it,
                // and SessionPublisher does not replay the current session.
                session { observers(replaySessionHost) }
            }
        }.onFailure { Log.e(TAG, "OTelService initialization failed", it) }.getOrNull()
        rum?.let(replaySessionHost::attach)

        if (rum != null) {
            sdkLoggerProvider?.let { loggerProvider ->
                // TODO(opentelemetry-android#764): Remove NativeExitCrashReporter once OTel Android
                // replays REASON_CRASH_NATIVE via ApplicationExitInfo in CrashReporter instrumentation.
                Thread({
                    try {
                        NativeExitCrashReporter.reportPendingNativeCrashes(
                            application,
                            loggerProvider,
                            sdkTracerProvider,
                        )
                    } catch (t: Throwable) {
                        Log.w(TAG, "Native exit crash replay failed", t)
                    }
                }, "native-exit-crash-replay").start()
            } ?: Log.w(TAG, "SDK logger provider unavailable; native crash replay skipped")
            Log.i(
                TAG,
                "OTelService initialized, exporting to $endpoint " +
                    "(diskBuffering=$diskBufferingEnabled)",
            )
        }
    }

    // `NativeExitCrashReporter` needs the concrete SDK providers, and reaching them takes two
    // unwraps. Since OTel-Android 1.5.0 `rum.openTelemetry` is a `DisableableOpenTelemetry` wrapper
    // rather than the SDK, and `OpenTelemetrySdk` then hands back package-private
    // `Obfuscated*Provider` types from the plain getters, specifically so callers cannot cast to the
    // SDK ones. Their `unobfuscate()` is public but the classes are not, hence reflection. The
    // supported alternative — `OpenTelemetryRumBuilder.addOtelReadyListener`, which receives the raw
    // SDK — is not reachable through the agent's `initialize` DSL.
    private val sdkLoggerProvider: SdkLoggerProvider?
        get() = rum?.openTelemetry?.logsBridge?.let { it as? SdkLoggerProvider ?: it.unobfuscate() }

    private val sdkTracerProvider: SdkTracerProvider?
        get() = rum?.openTelemetry?.tracerProvider?.let { it as? SdkTracerProvider ?: it.unobfuscate() }

    fun getTracer(instrumentationScope: String = INSTRUMENTATION_SCOPE) =
        openTelemetry.getTracer(instrumentationScope)

    fun getLoggerProvider() = openTelemetry.logsBridge

    companion object {
        private const val TAG = "OTelService"
        const val SERVICE_NAME = "quickpizza-android"
        const val INSTRUMENTATION_SCOPE = "com.grafana.quickpizza"

        private fun allowsLoopback(endpoint: String): Boolean {
            val host = runCatching { java.net.URI(endpoint).host }.getOrNull()?.lowercase() ?: return false
            return host == "localhost" || host == "127.0.0.1" || host == "10.0.2.2" || host == "::1"
        }
    }
}

// Top-level (rather than a class member) so the unit test can call it directly; `internal`
// keeps it out of the public API surface. `getMethod` only requires the *method* to be public,
// but `invoke` still enforces that the *declaring class* is accessible — which it isn't, since
// `Obfuscated*Provider` is package-private — so it throws IllegalAccessException unless we
// suppress that check with `isAccessible = true`.
internal inline fun <reified T : Any> Any.unobfuscate(): T? =
    runCatching {
        javaClass.getMethod("unobfuscate").apply { isAccessible = true }.invoke(this) as? T
    }.getOrNull()

package com.grafana.quickpizza.core.o11y

import android.app.Application
import android.util.Log
import com.grafana.quickpizza.core.config.AppConfig
import com.grafana.quickpizza.core.config.RuntimeConfigHolder
import com.grafana.quickpizza.nativecrash.NativeExitCrashReporter
import io.opentelemetry.android.OpenTelemetryRum
import io.opentelemetry.android.agent.OpenTelemetryRumInitializer
import io.opentelemetry.api.OpenTelemetry
import io.opentelemetry.api.common.AttributeKey
import io.opentelemetry.api.common.Attributes
import io.opentelemetry.api.logs.Severity
import io.opentelemetry.sdk.logs.SdkLoggerProvider
import io.opentelemetry.sdk.trace.SdkTracerProvider
import java.util.concurrent.TimeUnit
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

        // Captured before the OTel SDK installs its own handlers so we can fall back to the
        // real OS process-killer once we've flushed the crash.
        val osHandler = Thread.getDefaultUncaughtExceptionHandler()

        rum = runCatching {
            OpenTelemetryRumInitializer.initialize(application) {
                httpExport {
                    baseUrl = endpoint
                    if (authHeader != null) {
                        baseHeaders = mapOf("Authorization" to authHeader)
                    }
                }
                diskBuffering {
                    enabled(diskBufferingEnabled)
                }
                semanticConventions {
                    // Pin the pre-1.5.0 convention names (device.crash, screen.name, …) so the
                    // existing consumer keeps matching after the SDK bump.
                    useLatestExperimental = false
                }
                resource {
                    put(AttributeKey.stringKey("service.name"), "quickpizza-android")
                    put(AttributeKey.stringKey("service.namespace"), "quickpizza")
                    put(AttributeKey.stringKey("service.version"), appConfig.appVersion)
                }
            }
        }.onFailure { Log.e(TAG, "OTelService initialization failed", it) }.getOrNull()

        if (rum != null) {
            installCrashFlushHandler(osHandler)
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
            }
            Log.i(
                TAG,
                "OTelService initialized, exporting to $endpoint " +
                    "(diskBuffering=$diskBufferingEnabled)",
            )
        }
    }

    // Reaching the SDK providers takes two unwraps. Since OTel-Android 1.5.0 `rum.openTelemetry` is
    // a `DisableableOpenTelemetry` wrapper rather than the SDK, and `OpenTelemetrySdk` then hands
    // back package-private `Obfuscated*Provider` types from the plain getters, specifically so
    // callers cannot cast to the SDK ones. Their `unobfuscate()` is public but the classes are not,
    // hence reflection. The supported alternative — `OpenTelemetryRumBuilder.addOtelReadyListener`,
    // which receives the raw SDK — is not reachable through the agent's `initialize` DSL.
    private val sdkLoggerProvider: SdkLoggerProvider?
        get() = rum?.openTelemetry?.logsBridge?.let { it as? SdkLoggerProvider ?: it.unobfuscate() }

    private val sdkTracerProvider: SdkTracerProvider?
        get() = rum?.openTelemetry?.tracerProvider?.let { it as? SdkTracerProvider ?: it.unobfuscate() }

    private inline fun <reified T : Any> Any.unobfuscate(): T? =
        runCatching { javaClass.getMethod("unobfuscate").invoke(this) as? T }.getOrNull()

    /**
     * Guarantees unhandled-crash telemetry actually reaches the collector.
     *
     * OTel-Android (1.5.1-alpha) wires its crash flush incorrectly: the auto-installed
     * `CrashReporter` emits the `device.crash` log and then immediately delegates to the OS
     * process-killer, while the SDK's own `FlushOnCrashExceptionHandler` only force-flushes
     * *after* that delegation — i.e. after the process is already dead. The queued crash log is
     * dropped, so crashes never appear in the backend (handled exceptions are unaffected because
     * the process stays alive long enough for the normal batch flush).
     *
     * Delegating to `osHandler`, captured before SDK init, skips the SDK's handler chain entirely,
     * so the crash is emitted once even though `CrashReporter` is still installed.
     */
    private fun installCrashFlushHandler(osHandler: Thread.UncaughtExceptionHandler?) {
        val loggerProvider = sdkLoggerProvider ?: run {
            Log.w(TAG, "Crash flush handler not installed: logs bridge is not an SDK instance")
            return
        }
        val tracerProvider = sdkTracerProvider

        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                emitDeviceCrash(thread, throwable)
                loggerProvider.forceFlush().join(CRASH_FLUSH_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                tracerProvider?.forceFlush()?.join(CRASH_FLUSH_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            } catch (t: Throwable) {
                Log.w(TAG, "Failed to flush crash telemetry", t)
            } finally {
                if (osHandler != null) {
                    osHandler.uncaughtException(thread, throwable)
                } else {
                    android.os.Process.killProcess(android.os.Process.myPid())
                    kotlin.system.exitProcess(10)
                }
            }
        }
    }

    private fun emitDeviceCrash(thread: Thread, throwable: Throwable) {
        openTelemetry.logsBridge.get(CRASH_INSTRUMENTATION_SCOPE)
            .logRecordBuilder()
            .setEventName(DEVICE_CRASH_EVENT_NAME)
            .setSeverity(Severity.ERROR)
            .setAllAttributes(
                Attributes.builder()
                    .put(AttributeKey.longKey("thread.id"), thread.id)
                    .put(AttributeKey.stringKey("thread.name"), thread.name)
                    .put(AttributeKey.stringKey("exception.type"), throwable.javaClass.name)
                    .put(AttributeKey.stringKey("exception.message"), throwable.message ?: "")
                    .put(AttributeKey.stringKey("exception.stacktrace"), throwable.stackTraceToString())
                    .build(),
            )
            .emit()
    }

    fun getTracer(instrumentationScope: String = INSTRUMENTATION_SCOPE) =
        openTelemetry.getTracer(instrumentationScope)

    fun getLoggerProvider() = openTelemetry.logsBridge

    companion object {
        private const val TAG = "OTelService"
        const val INSTRUMENTATION_SCOPE = "com.grafana.quickpizza"
        private const val CRASH_INSTRUMENTATION_SCOPE = "io.opentelemetry.crash"
        private const val DEVICE_CRASH_EVENT_NAME = "device.crash"
        private const val CRASH_FLUSH_TIMEOUT_MS = 3_000L
    }
}

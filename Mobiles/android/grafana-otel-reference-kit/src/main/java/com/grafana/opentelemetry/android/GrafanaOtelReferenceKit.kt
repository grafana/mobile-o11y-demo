package com.grafana.opentelemetry.android

import android.app.Application
import io.opentelemetry.android.Incubating
import io.opentelemetry.android.OpenTelemetryRum
import io.opentelemetry.android.agent.OpenTelemetryRumInitializer
import io.opentelemetry.android.agent.dsl.OpenTelemetryConfiguration
import io.opentelemetry.api.common.AttributeKey
import kotlin.time.toKotlinDuration

/**
 * Marks Reference Kit APIs that expose an unstable upstream OpenTelemetry Android surface.
 */
@RequiresOptIn(
    message = "This API exposes an incubating upstream OpenTelemetry Android configuration surface.",
)
@Retention(AnnotationRetention.BINARY)
@Target(
    AnnotationTarget.CLASS,
    AnnotationTarget.FUNCTION,
    AnnotationTarget.PROPERTY,
    AnnotationTarget.CONSTRUCTOR,
)
annotation class ExperimentalGrafanaOtelApi

/**
 * Applies Grafana's Android defaults while preserving the upstream OpenTelemetry API and SDK.
 */
@OptIn(Incubating::class)
object GrafanaOtelReferenceKit {
    private val initialization = SingleInitialization<OpenTelemetryRum>()

    /**
     * Initializes the upstream Android RUM SDK and returns its native runtime object.
     *
     * The first call owns process-wide initialization. Later calls return its runtime instead of
     * installing duplicate exporters, lifecycle callbacks, and instrumentations. If initialization
     * fails, the process must restart before trying again because upstream setup may have already
     * registered lifecycle listeners. Treat the returned runtime as process-lifetime; after calling
     * [OpenTelemetryRum.shutdown], restart the process instead of calling initialize again.
     */
    @JvmStatic
    fun initialize(
        application: Application,
        configuration: GrafanaOtelConfiguration,
    ): OpenTelemetryRum = initializeOnce(application, configuration) {}

    /**
     * Initializes the upstream Android RUM SDK with access to its incubating configuration DSL.
     *
     * [configureUpstream] runs after the Reference Kit defaults. It is an escape hatch for
     * upstream SDK features and instrumentations that are not represented by this package.
    */
    @ExperimentalGrafanaOtelApi
    @JvmSynthetic
    @JvmStatic
    fun initialize(
        application: Application,
        configuration: GrafanaOtelConfiguration,
        configureUpstream: OpenTelemetryConfiguration.() -> Unit,
    ): OpenTelemetryRum = initializeOnce(application, configuration, configureUpstream)

    /** Returns the process-wide runtime after successful initialization. */
    @JvmStatic
    fun getInstanceOrNull(): OpenTelemetryRum? = initialization.getOrNull()

    private fun initializeOnce(
        application: Application,
        configuration: GrafanaOtelConfiguration,
        configureUpstream: OpenTelemetryConfiguration.() -> Unit,
    ): OpenTelemetryRum =
        initialization.getOrInitialize {
            OpenTelemetryRumInitializer.initialize(application) {
                applyReferenceKitConfiguration(configuration, configureUpstream)
            }
        }
}

internal fun OpenTelemetryConfiguration.applyReferenceKitConfiguration(
    configuration: GrafanaOtelConfiguration,
    configureUpstream: OpenTelemetryConfiguration.() -> Unit = {},
) {
    httpExport {
        baseUrl = configuration.otlpEndpoint
        baseHeaders = configuration.headers
    }
    diskBuffering {
        enabled(configuration.diskBufferingEnabled)
    }
    semanticConventions {
        useLatestExperimental = configuration.useLatestExperimentalSemanticConventions
    }
    session {
        backgroundInactivityTimeout =
            configuration.sessionBackgroundInactivityTimeout.toKotlinDuration()
        maxLifetime = configuration.sessionMaxLifetime.toKotlinDuration()
    }
    resource {
        putAll(configuration.resourceAttributes)
        put(AttributeKey.stringKey("service.name"), configuration.serviceName)
        configuration.serviceNamespace?.let {
            put(AttributeKey.stringKey("service.namespace"), it)
        }
        configuration.serviceVersion?.let {
            put(AttributeKey.stringKey("service.version"), it)
        }
    }
    configureUpstream()
}

internal class SingleInitialization<T : Any> {
    private val lock = Any()

    @Volatile
    private var value: T? = null
    private var failure: Throwable? = null
    private var initializing = false

    fun getOrNull(): T? = value

    fun getOrInitialize(initializer: () -> T): T {
        value?.let { return it }

        return synchronized(lock) {
            value?.let { return@synchronized it }
            failure?.let {
                throw IllegalStateException(
                    "Initialization previously failed; restart the process before retrying",
                    it,
                )
            }
            check(!initializing) { "Initialization is already in progress on this thread" }

            initializing = true
            try {
                initializer().also { value = it }
            } catch (throwable: Throwable) {
                failure = throwable
                throw throwable
            } finally {
                initializing = false
            }
        }
    }
}

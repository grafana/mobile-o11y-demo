package com.grafana.opentelemetry.android

import android.app.Application
import io.opentelemetry.android.OpenTelemetryRum
import io.opentelemetry.android.agent.OpenTelemetryRumInitializer
import io.opentelemetry.android.agent.dsl.DiskBufferingConfigurationSpec
import io.opentelemetry.android.agent.dsl.HttpExportConfiguration
import io.opentelemetry.android.agent.dsl.OpenTelemetryConfiguration
import io.opentelemetry.android.agent.dsl.SemanticConventionsConfiguration
import io.opentelemetry.android.agent.dsl.SessionConfiguration
import io.opentelemetry.android.agent.dsl.instrumentation.InstrumentationConfiguration
import io.opentelemetry.api.common.AttributeKey
import io.opentelemetry.api.common.Attributes
import io.opentelemetry.sdk.common.Clock
import io.opentelemetry.sdk.resources.ResourceBuilder
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
@OptIn(ExperimentalGrafanaOtelApi::class)
object GrafanaOtelReferenceKit {
    private val initialization = SingleInitialization<OpenTelemetryRum>()

    /**
     * Initializes the upstream Android RUM SDK and returns its native runtime object.
     *
     * Call this from [Application.onCreate] on the main thread.
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
     * [configureUpstream] runs after the Reference Kit defaults. It exposes selected upstream SDK
     * settings and makes resource customization additive so required Grafana attributes remain.
     * Metrics remain disabled after this callback because Faro OTLP ingest accepts logs and traces
     * only; configuring a metrics endpoint in [configureUpstream] has no effect in this spike.
     */
    @ExperimentalGrafanaOtelApi
    @JvmSynthetic
    @JvmStatic
    fun initialize(
        application: Application,
        configuration: GrafanaOtelConfiguration,
        configureUpstream: GrafanaOtelUpstreamConfiguration.() -> Unit,
    ): OpenTelemetryRum = initializeOnce(application, configuration, configureUpstream)

    /** Returns the process-wide runtime after successful initialization. */
    @JvmStatic
    fun getInstanceOrNull(): OpenTelemetryRum? = initialization.getOrNull()

    private fun initializeOnce(
        application: Application,
        configuration: GrafanaOtelConfiguration,
        configureUpstream: GrafanaOtelUpstreamConfiguration.() -> Unit,
    ): OpenTelemetryRum =
        initialization.getOrInitialize {
            OpenTelemetryRumInitializer.initialize(application) {
                applyReferenceKitConfiguration(configuration, configureUpstream)
            }
        }
}

@OptIn(ExperimentalGrafanaOtelApi::class)
@JvmSynthetic
internal fun OpenTelemetryConfiguration.applyReferenceKitConfiguration(
    configuration: GrafanaOtelConfiguration,
    configureUpstream: GrafanaOtelUpstreamConfiguration.() -> Unit = {},
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
    val upstreamConfiguration =
        GrafanaOtelUpstreamConfiguration.create(this).apply(configureUpstream)
    resource {
        putAll(configuration.resourceAttributes)
        upstreamConfiguration.applyResource(this)
        put(AttributeKey.stringKey("service.name"), configuration.serviceName)
        configuration.serviceNamespace?.let {
            put(AttributeKey.stringKey("service.namespace"), it)
        }
        configuration.serviceVersion?.let {
            put(AttributeKey.stringKey("service.version"), it)
        }
    }
    // Faro OTLP ingest currently accepts logs and traces only.
    disableMetrics()
}

/**
 * Selected upstream configuration that remains experimental until the package is published.
 *
 * Resource actions are additive. Grafana's required service attributes are applied after them.
 */
@ExperimentalGrafanaOtelApi
class GrafanaOtelUpstreamConfiguration private constructor(
    private val delegate: OpenTelemetryConfiguration,
) {
    private val resourceActions = mutableListOf<ResourceBuilder.() -> Unit>()

    var clock: Clock
        get() = delegate.clock
        set(value) {
            delegate.clock = value
        }

    fun httpExport(action: HttpExportConfiguration.() -> Unit) = delegate.httpExport(action)

    fun instrumentations(action: InstrumentationConfiguration.() -> Unit) =
        delegate.instrumentations(action)

    fun semanticConventions(action: SemanticConventionsConfiguration.() -> Unit) =
        delegate.semanticConventions(action)

    fun session(action: SessionConfiguration.() -> Unit) = delegate.session(action)

    fun globalAttributes(action: () -> Attributes) = delegate.globalAttributes(action)

    fun globalAttributesSupplier(action: () -> (() -> Attributes)) =
        delegate.globalAttributesSupplier(action)

    fun diskBuffering(action: DiskBufferingConfigurationSpec.() -> Unit) =
        delegate.diskBuffering(action)

    fun resource(action: ResourceBuilder.() -> Unit) {
        resourceActions += action
    }

    @JvmSynthetic
    internal fun applyResource(builder: ResourceBuilder) {
        resourceActions.forEach { it.invoke(builder) }
    }

    companion object {
        @JvmSynthetic
        internal fun create(delegate: OpenTelemetryConfiguration) =
            GrafanaOtelUpstreamConfiguration(delegate)
    }
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

# Grafana OTel Reference Kit for Android (spike)

This local Android library tests the package boundary proposed in
[frontend-o11y-knowledge-workbench#113](https://github.com/grafana/frontend-o11y-knowledge-workbench/issues/113).
It is not published and is not yet a supported SDK.

The module owns Grafana-oriented startup defaults and delegates all SDK behavior to
[`opentelemetry-android`](https://github.com/open-telemetry/opentelemetry-android). It returns the
upstream `OpenTelemetryRum` object, so application instrumentation continues to use standard
OpenTelemetry APIs.

## Requirements

- Android `minSdk` 23 or newer.
- The `opentelemetry-android` `1.5.1-alpha` BOM, which selects `android-agent` `1.5.1`.
- For applications with `minSdk` below 26, enable core-library desugaring and add
  `com.android.tools:desugar_jdk_libs` (the demo uses `2.1.4`).
- With Android Gradle Plugin 8.3 or newer, set
  `android.useFullClasspathForDexingTransform=true` in `gradle.properties`.

```kotlin
val rum = GrafanaOtelReferenceKit.initialize(
    application = this,
    configuration = GrafanaOtelConfiguration(
        otlpEndpoint = "https://collector.example/otlp/app-key",
        serviceName = "my-android-app",
        serviceVersion = BuildConfig.VERSION_NAME,
    ),
)

val tracer = rum.openTelemetry.getTracer("com.example.app")
```

Initialization is process-wide. The first call creates the runtime; later calls return that same
instance rather than installing a second set of exporters and instrumentations. If startup fails,
the Reference Kit does not retry in that process because upstream setup may already have registered
lifecycle listeners. Restart the process after correcting the configuration.

Treat the returned `OpenTelemetryRum` as process-lifetime. If the application calls its
`shutdown()` method, restart the process before initializing telemetry again.

The optional Kotlin-only `configureUpstream` block is applied last. It provides direct access to
the upstream Android configuration DSL when an application needs an instrumentation or SDK option
that the Reference Kit does not model. The Kotlin compiler requires opt-in to
`ExperimentalGrafanaOtelApi` because the block follows an unstable upstream surface. Java callers
use the stable two-argument `initialize` method.

Use `GrafanaOtelConfiguration.resourceAttributes` to add resource attributes. In upstream 1.5.1,
calling `resource {}` from `configureUpstream` replaces the complete resource action rather than
merging with it, so callers that use that escape hatch must also restate `service.name` and any
other required resource attributes.

The spike exposes Java-callable configuration and a stable startup method. A binary API
compatibility check is still required before the module is extracted and published as a versioned
AAR.

See [the spike decision and validation note](../../docs/ANDROID_REFERENCE_KIT_SPIKE.md) for the
proposed production location, package boundary, migration, removal, and remaining gates.

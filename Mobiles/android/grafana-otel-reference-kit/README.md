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
- Automatic OkHttp spans remain application-owned. The QuickPizza app applies the Byte Buddy plugin
  and the upstream `okhttp3-agent`; the Reference Kit does not add them.

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

Call `initialize` from `Application.onCreate` on the main thread. Initialization is process-wide.
The first call creates the runtime; later calls return that same instance rather than installing a
second set of exporters and instrumentations. If startup fails, the Reference Kit does not retry in
that process because upstream setup may already have registered lifecycle listeners. Restart the
process after correcting the configuration.

Treat the returned `OpenTelemetryRum` as process-lifetime. If the application calls its
`shutdown()` method, restart the process before initializing telemetry again.

The optional Kotlin-only `configureUpstream` block is applied after the Reference Kit defaults. It
exposes selected upstream instrumentation and SDK settings through
`GrafanaOtelUpstreamConfiguration`. Resource actions in that block are additive, and the configured
Grafana service attributes are applied last. The Kotlin compiler requires opt-in to
`ExperimentalGrafanaOtelApi` because the block follows an unstable upstream surface. Java callers
use the stable two-argument `initialize` method.

Faro OTLP ingest currently accepts logs and traces, so this spike disables the upstream periodic
metric exporter after applying `configureUpstream`. Configuring a metrics endpoint in that block has
no effect. A production package needs explicit per-signal routing before it can support metrics
through another endpoint.

## Configuration defaults

| Setting | Default |
| --- | --- |
| `headers` | Empty |
| `serviceNamespace` / `serviceVersion` | Not set |
| `resourceAttributes` | Empty |
| `diskBufferingEnabled` | `true` |
| `useLatestExperimentalSemanticConventions` | `false` |
| `sessionBackgroundInactivityTimeout` | 15 minutes |
| `sessionMaxLifetime` | 4 hours |

`otlpEndpoint` and `serviceName` are required. The endpoint must begin with lowercase `http://` or
`https://` and must not contain a query string or fragment. HTTP remains useful for emulator loopback
tests, while production endpoints should use HTTPS. Header names must use visible ASCII characters,
and header values may use tabs or visible ASCII characters.

The spike exposes Java-callable configuration and a stable startup method. A binary API
compatibility check is still required before the module is extracted and published as a versioned
AAR.

See [the spike decision and validation note](../../docs/ANDROID_REFERENCE_KIT_SPIKE.md) for the
proposed production location, package boundary, migration, removal, and remaining gates.

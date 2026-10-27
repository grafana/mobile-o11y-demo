# Grafana OpenTelemetry Android

This local Android library is the Grafana OpenTelemetry Android composition spike. It is not
published and is not yet a supported SDK. QuickPizza consumes it as a project dependency while the
separate repository and publishing setup are agreed.

The module owns Grafana-oriented startup defaults and delegates all SDK behavior to
[`opentelemetry-android`](https://github.com/open-telemetry/opentelemetry-android). It returns the
upstream `OpenTelemetryRum` object, so application instrumentation continues to use standard
OpenTelemetry APIs.

## Requirements

- Android `minSdk` 23 or newer.
- The `opentelemetry-android` `1.7.0-alpha` BOM, which selects `android-agent` `1.7.0`.
- `compileSdk` 37 and Android Gradle Plugin 9.1.0 or newer for the upstream AndroidX dependencies.
  This demo uses AGP 9.1.1 and Gradle 9.3.1.
- For applications with `minSdk` below 26, enable core-library desugaring and add
  `com.android.tools:desugar_jdk_libs` (the demo uses `2.1.4`).
- With Android Gradle Plugin 8.3 or newer, set
  `android.useFullClasspathForDexingTransform=true` in `gradle.properties`.
- Automatic OkHttp spans remain application-owned; this library does not add them. QuickPizza
  wraps its client with `OkHttpTelemetry.create(openTelemetry).createCallFactory(client)` from
  `okhttp3-library` / `opentelemetry-okhttp-3.0`, and also applies the Byte Buddy plugin with the
  upstream `okhttp3-agent`.

QuickPizza's dependencies, with versions in
[`gradle/libs.versions.toml`](../gradle/libs.versions.toml):

```kotlin
plugins {
    id("net.bytebuddy.byte-buddy-gradle-plugin")
}

dependencies {
    implementation(platform("io.opentelemetry.android:opentelemetry-android-bom:1.7.0-alpha"))
    implementation(project(":grafana-opentelemetry-android"))
    implementation("io.opentelemetry:opentelemetry-sdk")
    implementation("io.opentelemetry.android.instrumentation:compose-navigation:1.7.0-alpha")
    implementation("io.opentelemetry.android.instrumentation:okhttp3-library:1.7.0-alpha")
    implementation("io.opentelemetry.instrumentation:opentelemetry-okhttp-3.0")
    byteBuddy("io.opentelemetry.android.instrumentation:okhttp3-agent:1.7.0-alpha")
}
```

The library itself depends on `io.opentelemetry.android:android-agent` through the same BOM.

```kotlin
val rum = GrafanaOtel.initialize(
    application = this,
    configuration = GrafanaOtelConfiguration(
        // Faro OTLP ingest: https://faro-collector-<region>.grafana.net/otlp/<appKey>.
        // OTLP base URL; the agent appends /v1/traces and /v1/logs. No auth header needed.
        otlpEndpoint = "https://collector.example/otlp/app-key",
        serviceName = "my-android-app",
        serviceVersion = BuildConfig.VERSION_NAME,
        // Optional: headers = mapOf(...), resourceAttributes = Attributes.of(...)
    ),
)

val tracer = rum.openTelemetry.getTracer("com.example.app")
```

Call `initialize` from `Application.onCreate` on the main thread. Initialization is process-wide.
The first call creates the runtime; later calls return that same instance rather than installing a
second set of exporters and instrumentations. If startup fails, the library does not retry in
that process because upstream setup may already have registered lifecycle listeners. Restart the
process after correcting the configuration.

Treat the returned `OpenTelemetryRum` as process-lifetime. If the application calls its
`shutdown()` method, restart the process before initializing telemetry again.

The optional Kotlin-only `configureUpstream` block is applied after the Grafana defaults. It
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

See [the spike decision and validation note](../../docs/GRAFANA_OPENTELEMETRY_ANDROID.md) for the
proposed production location, package boundary, migration, removal, and remaining gates.

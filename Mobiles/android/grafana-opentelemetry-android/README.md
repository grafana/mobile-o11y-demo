# Grafana OpenTelemetry Android

An experimental, unpublished Android library that applies Grafana startup defaults and delegates
all SDK behavior to [`opentelemetry-android`](https://github.com/open-telemetry/opentelemetry-android).
It returns the upstream `OpenTelemetryRum`, so application instrumentation keeps using standard
OpenTelemetry APIs. QuickPizza consumes it as a project dependency. The boundary, removal steps and
open gates are in the [decision record](../../docs/GRAFANA_OPENTELEMETRY_ANDROID.md).

## Requirements

- `minSdk` 23 or newer, `compileSdk` 37 and Android Gradle Plugin 9.1 or newer.
- Below API 26, enable core-library desugaring and add `com.android.tools:desugar_jdk_libs`.
- With AGP 8.3 or newer, set `android.useFullClasspathForDexingTransform=true` in
  `gradle.properties`.
- OkHttp spans are not added by this library. QuickPizza adds them itself; see
  [the app README](../README.md#observability).

## Add the dependency

QuickPizza's wiring in `app/build.gradle.kts`, using aliases from
[`gradle/libs.versions.toml`](../gradle/libs.versions.toml), which pins the versions:

```kotlin
plugins {
    alias(libs.plugins.bytebuddy)
}

dependencies {
    implementation(platform(libs.opentelemetry.android.bom))
    implementation(project(":grafana-opentelemetry-android"))
    implementation(libs.opentelemetry.sdk)
    implementation(libs.opentelemetry.android.compose.navigation)
    implementation(libs.opentelemetry.android.okhttp3.library)
    implementation(libs.opentelemetry.okhttp3)
    byteBuddy(libs.opentelemetry.android.okhttp3.agent)
}
```

| Alias | Maven coordinates |
| --- | --- |
| `libs.plugins.bytebuddy` | plugin `net.bytebuddy.byte-buddy-gradle-plugin` |
| `opentelemetry.android.bom` | `io.opentelemetry.android:opentelemetry-android-bom` |
| `opentelemetry.sdk` | `io.opentelemetry:opentelemetry-sdk` |
| `opentelemetry.android.compose.navigation` | `io.opentelemetry.android.instrumentation:compose-navigation` |
| `opentelemetry.android.okhttp3.library` | `io.opentelemetry.android.instrumentation:okhttp3-library` |
| `opentelemetry.okhttp3` | `io.opentelemetry.instrumentation:opentelemetry-okhttp-3.0` |
| `opentelemetry.android.okhttp3.agent` | `io.opentelemetry.android.instrumentation:okhttp3-agent` |

The three `io.opentelemetry.android.instrumentation` artifacts carry their own version in the
catalog; the rest take it from the BOM. The library itself depends on
`io.opentelemetry.android:android-agent` through the same BOM.

The API is in package `com.grafana.opentelemetry.android` (`GrafanaOtel`,
`GrafanaOtelConfiguration`).

## Initialize

```kotlin
val rum = GrafanaOtel.initialize(
    application = this,
    configuration = GrafanaOtelConfiguration(
        // OTLP base URL; the agent appends /v1/traces and /v1/logs.
        // Faro OTLP ingest needs no auth header.
        otlpEndpoint = "https://faro-collector-<region>.grafana.net/otlp/<appKey>",
        serviceName = "my-android-app",
        serviceVersion = BuildConfig.VERSION_NAME,
        // Optional: headers = mapOf(...), resourceAttributes = Attributes.of(...)
    ),
)

val tracer = rum.openTelemetry.getTracer("com.example.app")
```

Call `initialize` from `Application.onCreate` on the main thread. Initialization is process-wide:
later calls return the same instance. If startup fails, the library does not retry in that process,
because upstream setup may already have registered lifecycle listeners. Fix the configuration and
restart the process. Treat the returned `OpenTelemetryRum` as process-lifetime; after `shutdown()`,
restart the process before initializing again.

The optional Kotlin-only `configureUpstream` block runs after the Grafana defaults and exposes
selected upstream settings through `GrafanaOtelUpstreamConfiguration`. It requires opt-in to
`ExperimentalGrafanaOtelApi`. Its `resource {}` actions are additive, and the Grafana service
attributes are applied last. Metric export stays disabled even if the block configures it. Java
callers use the stable two-argument `initialize` method.

## Configuration defaults

| Setting | Type | Default |
| --- | --- | --- |
| `headers` | `Map<String, String>` | Empty |
| `serviceNamespace` / `serviceVersion` | `String?` | Not set |
| `resourceAttributes` | `io.opentelemetry.api.common.Attributes` | Empty |
| `diskBufferingEnabled` | `Boolean` | `true` |
| `useLatestExperimentalSemanticConventions` | `Boolean` | `false` |
| `sessionBackgroundInactivityTimeout` | `java.time.Duration` | 15 minutes |
| `sessionMaxLifetime` | `java.time.Duration` | 4 hours |

`otlpEndpoint` and `serviceName` are required. The endpoint must start with lowercase `http://` or
`https://` and must not contain a query string or fragment. Use HTTP only for emulator loopback
tests. Header names must be visible ASCII; header values may also contain tabs.

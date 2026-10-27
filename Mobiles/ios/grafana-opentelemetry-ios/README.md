# Grafana OpenTelemetry iOS

Unpublished local Swift package, not a supported SDK. It assembles the consolidated
[`opentelemetry-swift`](https://github.com/open-telemetry/opentelemetry-swift) pieces with Grafana's
defaults and returns the upstream providers, so apps keep instrumenting through standard
OpenTelemetry APIs. QuickPizza consumes it as a local package reference. Decision record and open
gates: [GRAFANA_OPENTELEMETRY_IOS.md](../../docs/GRAFANA_OPENTELEMETRY_IOS.md).

## Requirements

- **iOS 15**, the floor of the pinned upstream revision.
- **`swift-tools-version:6.2`** (Xcode 26 or later), matching upstream, so the package builds in
  Swift 6 language mode.
- **Upstream pin:** `opentelemetry-swift` revision
  [`ce0b2494`](https://github.com/open-telemetry/opentelemetry-swift/commit/ce0b249467c3d28f6340e6e26ff12ee20a8bfe8a)
  (merged #1218), set in [`Package.swift`](Package.swift). It is an unreleased commit; the emitted
  `telemetry.sdk.version` still says `2.6.0`. Repeat release validation before replacing it with a
  published version.

macOS 12 is declared only so `swift build` and `swift test` have a host platform. It is not a
supported target. tvOS, watchOS and visionOS are not built or tested.

## Usage

```swift
import GrafanaOpenTelemetryIOS

let runtime = try GrafanaOtel.initialize(
    configuration: try GrafanaOtelConfiguration(
        // OTLP base URL; the package appends /v1/traces and /v1/logs.
        otlpEndpoint: URL(string: "https://faro-collector-<region>.grafana.net/otlp/<appKey>")!,
        // Only these hosts receive traceparent. Exact host match, no default.
        firstPartyHosts: ["api.my-app.example"],
        serviceVersion: "1.4.0",
        deploymentEnvironment: "production"
    ),
    experimental: GrafanaOtelExperimentalOptions(
        // Strips trace context from redirects to other hosts on delegate-less URLSessions.
        automaticRedirectProtection: true,
        // Surfaces export failures such as a 404 or 401 ingest URL.
        diagnosticsHandler: { message in print("OTel: \(message)") }
    )
)

let tracer = runtime.openTelemetry.tracerProvider.get(
    instrumentationName: "com.example.app",
    instrumentationVersion: "1.0.0"
)
```

Full initializers. Swift labels must appear in this order; omit any defaulted one:

```swift
import GrafanaOpenTelemetryIOS
import OpenTelemetrySdk  // only for SpanProcessor / LogRecordProcessor

try GrafanaOtelConfiguration(
    otlpEndpoint: URL,
    firstPartyHosts: [String],
    serviceVersion: String? = nil,
    deploymentEnvironment: String? = nil,
    resourceAttributes: [String: String] = [:],
    headers: [String: String] = [:],
    sessionInactivityTimeout: TimeInterval = 900,
    sessionMaxLifetime: TimeInterval = 14_400,
    restorePersistedSession: Bool = false,
    diskBuffering: GrafanaOtelDiskBuffering = .enabledInDefaultDirectory,
    instrumentation: GrafanaOtelInstrumentationOptions = .default  // (urlSession:sessionEvents:metricKitDiagnostics:)
)

GrafanaOtelExperimentalOptions(
    additionalSpanProcessors: [SpanProcessor] = [],
    additionalLogRecordProcessors: [LogRecordProcessor] = [],
    customizeURLSession: ((inout URLSessionInstrumentationConfiguration) -> Void)? = nil,
    automaticRedirectProtection: Bool = false,
    diagnosticsHandler: (@Sendable (String) -> Void)? = nil,
    sessionSampler: any SessionSampler = AlwaysOnSessionSampler()
)
```

Instrument through `OpenTelemetryApi`. The package depends on `opentelemetry-swift`, but to import
its modules directly, add that package to your app at the revision in [`Package.swift`](Package.swift).

Rules:

- Call `initialize` once, early, on the **main thread**. Upstream's device and OS resource
  providers call `DispatchQueue.main.sync`, so a background call deadlocks if the main thread is
  waiting on it. An off-main call emits a diagnostic rather than trapping.
- Initialization is process-wide. Later calls return the same runtime; concurrent callers wait for
  the first.
- A failed `initialize` is not retried in that process, because upstream may already hold global
  state. Fix the configuration and restart.
- Treat the runtime as process-lifetime. After `shutdown()`, restart before initializing again.

## Why it exists

`opentelemetry-swift` has no assembled RUM agent (no `OpenTelemetryRum`). It ships providers,
exporters, session processors and instrumentations separately and leaves the ordering to each app.
This package does that wiring once.

## Package boundary

The package owns:

- the OTLP endpoint, its signal paths and export headers;
- the service and additional resource attributes;
- session inactivity, maximum lifetime and cold-start restore;
- the HTTP semantic convention (fixed at stable);
- which hosts receive W3C trace-context headers;
- disk buffering, its directory and backup policy;
- excluding its own collector origin (host **and** port) from HTTP tracing;
- sanitising the URL recorded on HTTP spans;
- draining and stopping the disk queue, which no provider reaches;
- the install order.

It defines no Grafana tracer, span, logger, event or meter API. `GrafanaOtelRuntime` exposes
upstream types plus `redirectGuard`, a delegate the app installs on its own `URLSession`s.

No `MeterProvider` is registered. Faro OTLP ingest accepts logs and traces only. The pinned
upstream does include a metrics SDK.

## Install order

The order is load-bearing, and getting it wrong fails silently. It matches
[`GrafanaOtel.swift`](Sources/GrafanaOpenTelemetryIOS/GrafanaOtel.swift).

Before taking the init lock, `initialize` builds the upstream default resource. Its providers hop
to the main queue, so building it under the lock could deadlock a main-thread status read against a
background initializer. Then `install` runs:

1. The diagnostics handler, so problems in later steps are observable.
2. One `SessionManager`, registered and passed explicitly to `SessionTraceSampler` and
   `SessionSamplingLogRecordProcessor`. Anything that resolves
   `SessionManagerProvider.getInstance()` before registration lazily creates a default manager with
   a 30-minute timeout, and registering later does not fix it.
3. Everything that can fail: storage directories, exporters and both pipelines. Nothing after this
   throws, so a failure never leaves a globally registered provider behind.
4. The tracer and logger providers, registered globally.
5. `SessionEventInstrumentation.install()`, after the logger provider, so queued `session.start`
   records do not go to the no-op logger.
6. The instrumentations last. `URLSessionInstrumentationConfiguration.init` and
   `MetricKitConfiguration.init` resolve a `Tracer`/`Logger` from the globals at construction, so
   anything built earlier is wired to a no-op provider and drops all data.

## Configuration defaults

| Setting | Default |
| --- | --- |
| `otlpEndpoint` | Required |
| `firstPartyHosts` | Required |
| `serviceVersion` | Not set by the package; upstream adds a bundle-derived `"<short version> (<build>)"` |
| `deploymentEnvironment` | Not set. Recorded as `deployment.environment.name` |
| `resourceAttributes` | Empty; the only route to `service.name` / `service.namespace` |
| `headers` | Empty |
| `sessionInactivityTimeout` | 15 minutes |
| `sessionMaxLifetime` | 4 hours |
| `restorePersistedSession` | `false` (new session on each cold start) |
| `diskBuffering` | `.enabledInDefaultDirectory` |
| `instrumentation` | `URLSession`, session events and MetricKit all on |

**No install-without-export mode.** If the app can run without telemetry, skip `initialize`.
Don't pass a placeholder: an unreachable endpoint still creates exporters and queues telemetry on
disk.

**No `serviceName` setting.** Upstream always derives `service.name` from the bundle name; the
package removes it. Frontend Observability shows the app under the name registered for the app key
in the endpoint. The OTLP gateway has no registered app, so for it pass `service.name` and
`service.namespace` in `resourceAttributes`; an explicit value there is kept.

**Validation** (fails at the call site):

- Endpoint: absolute `http://` or `https://`, no query or fragment, the OTLP **base** URL (not
  ending in `/v1/traces`, `/v1/logs` or `/v1/metrics`). HTTP is for simulator loopback.
- `firstPartyHosts`: bare hosts only. A scheme, port or path would match nothing. IPv6 literals are
  rejected; use a hostname or IPv4 address.
- Header names: visible ASCII. Values: visible ASCII or tab.
- Resource attribute keys: 1–255 printable ASCII characters. Upstream's `Resource(attributes:)`
  discards **every** attribute if any key is invalid.

**Tuning is not exposed.** Upstream defaults apply: 5 s schedule delay, 30 s export timeout, 2048
queue, 10 s HTTP timeout, gzip. One exception: the export batch is 512 records to the network but
**128 when buffering to disk**, because persistence JSON-encodes a whole batch under a 256 KiB cap
and an oversized write fails silently. Transport settings live in upstream's
`OtlpConfiguration`, which is not an exposed SPM product, so they are not configurable here.

### Endpoint and headers

The package appends `/v1/traces` and `/v1/logs` to the base URL, normalising a trailing slash.

Configured `headers` merge with `OTEL_EXPORTER_OTLP_HEADERS` and win on a case-insensitive name
match. The package parses the variable itself and splits on the **first** `=` only; upstream drops
values containing `=`, including padded base64 `Basic` credentials. Duplicate names are removed,
because the exporter comma-appends repeats.

### HTTP semantic conventions

Always stable: `http.request.method`, `url.full`, `http.response.status_code`, never upstream's
default legacy `http.method` / `http.url` / `http.status_code`. A `customizeURLSession` callback that
sets `semanticConvention` is overridden.

### Recorded request URLs

Upstream records `absoluteString`, query and credentials included. The package always rewrites
`url.full` with query, fragment, user and password removed, after any `customizeURLSession`
callback.

## Sessions

- One explicit `SessionManager` feeds `SessionTraceSampler` (the tracer provider's sampler) and
  `SessionSamplingLogRecordProcessor`. `SessionSpanProcessor` and `SessionLogRecordProcessor` are
  **not** installed; a second lookup could replace the sampled session snapshot across a reset.
- Spans and logs carry `session.id` and, after a cold start, `session.previous_id`. Faro rejects
  signals without `session.id` when session management is on.
- The log filter sits before batching and disk buffering. Replayed records keep their original
  session and decision; replay never consults the current session.
- The experimental `sessionSampler` defaults to always-on. The trace sampler stays parent-based, so
  an unsampled parent is respected.
- Defaults: 900 s inactivity, 14,400 s maximum lifetime, `restorePersistedSession: false`.
- Don't register your own `SessionManager` before `initialize`. The package installs its own.
- No meter provider is registered. If you add metrics yourself, apply the session decision before
  aggregation:

  ```swift
  let session = SessionManagerProvider.getInstance().getSession()
  session.recordIfSampled { attributes in
    counter.add(value: 1, attributes: attributes)
  }
  ```

App extensions and App Group persistence: see
[session validation](../session-validation/README.md#process-and-extension-ownership).

## Disk buffering

On by default, with the same guarantee for both signals. Span and log batches, MetricKit
diagnostics included, retry from disk, survive relaunch and deliver after connectivity returns. Both
exporters return `.failure` on a failed upload, so the persistence decorator keeps the batch. Both
use `requeueOnFailure: false` under persistence, so the disk queue is the only retry and nothing is
sent twice.

The default directory is under Application Support (not reclaimed under storage pressure), and the
package sets `isExcludedFromBackupKey` on it, because the queue holds full payloads.

`.enabled(storageURL:)` uses a directory you own. The package creates it and its two signal
subdirectories but does **not** change its backup policy. Set `isExcludedFromBackupKey` yourself.

Latency: records become readable after about 4.75 s, then export on an adaptive 1–20 s cycle. Pass
`.disabled` for prompt delivery, at the cost of losing whatever is queued at termination.

## Trace-context propagation

Upstream injects `traceparent`, `tracestate` and `baggage` into every instrumented request.
`firstPartyHosts` narrows that and has no default. Matching is **exact** and case-insensitive:
`["example.com"]` does not cover `api.example.com`, so list every host. An empty array propagates
to nothing. A `customizeURLSession` callback can narrow the list but not widen it.

### Redirects

The host list applies when the request is created. `URLSession` copies custom headers onto a `3xx`
follow-up, so a first-party request redirected to a third party carries `traceparent` there.
Upstream has no redirect hook. Two opt-in fixes:

**`automaticRedirectProtection` (most apps).** Covers tasks with neither a task nor a session
delegate, which is what `URLSession.shared` with `async`/`await` gives you:

```swift
GrafanaOtelExperimentalOptions(automaticRedirectProtection: true)
```

It adds the redirect callback to two internal upstream delegate classes. It is skipped where an
implementation already exists, and a rename is reported through `diagnosticsHandler`. QuickPizza
uses this.

**`GrafanaOtelRuntime.redirectGuard`** for sessions with a delegate of their own:

```swift
URLSession(configuration: .default, delegate: runtime.redirectGuard, delegateQueue: nil)

// or per task
let (data, response) = try await URLSession.shared.data(
  for: request,
  delegate: GrafanaOtel.runtime?.redirectGuard
)
```

If you already have a delegate, call `redirectGuard.sanitizedRedirect(_:)` from your
`urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`.

Giving a task or session a delegate makes upstream skip its `AsyncTaskDelegate`, which ends spans
for `async`/`await` requests. The guard implements `urlSession(_:task:didCompleteWithError:)` so
upstream swizzles it and spans still end. A delegate of your own that implements none of the
selectors `URLSessionInstrumentation` scans for silently drops those spans.

| | `automaticRedirectProtection` | `redirectGuard` |
| --- | --- | --- |
| Delegate-less sessions | covered | covered |
| Sessions with your own delegate | not covered | covered |
| Survives an upstream rename of internal classes | no; reported through `diagnosticsHandler` | yes |
| App code | one line at startup | a delegate on each session |

Both apply the same host policy, so a redirect that stays on the list keeps its context.

## Known limitations

Properties of the pinned upstream, not of this package's configuration:

- **No lifecycle or screen-view instrumentation.** App start, foreground/background, `screen.view`
  and jank stay app-owned.
- **Crashes and hangs are MetricKit-only.** [Apple documents immediate diagnostic delivery on
  iOS 15+](https://developer.apple.com/documentation/metrickit), separately from daily metric
  reports. No signal handler, no crash replay, no guaranteed report for a deliberate crash.
- **MetricKit diagnostics get the session active at delivery**, not the one that crashed. See the
  [MetricKit boundary](../session-validation/README.md#metrickit-boundary).
- **No backoff and no delivery signal to the app.** No `Retry-After` handling. A wrong ingest URL
  looks like a working one from inside the app; only `diagnosticsHandler` shows the 404 or 401.
- **No flush on background or termination.** Call `GrafanaOtelRuntime.forceFlush()` from your own
  hooks, but **not on the main thread**: it blocks on synchronous export, up to the 10 s transport
  timeout per pending batch.
- **A provider flush does not reach the disk queue.** Batch processors' `forceFlush` writes to
  disk and returns. The runtime holds the persistence exporters and drains them as a second step.
- **`shutdown()` gates the persistence workers rather than cancelling them.** Upstream's
  `DataExportWorkerProtocol` exposes no cancel, so the package closes an `exportCondition` it owns.
  Queued data still delivers; nothing exports afterwards; idle workers stay parked.
- **`LoggerProviderSdk` has no flush or shutdown.** The runtime keeps the log processor and flushes
  through the session decorator.
- **Session inactivity is signal-based.** Session-aware spans and logs count as activity, including
  background HTTP, so "15 minutes" means no span and no log, not Faro's user-interaction rule.
- **`URLSession` instrumentation cannot be uninstalled**, and one configuration wins per process.
  Use `customizeURLSession`; a second instance would chain swizzles and double-instrument.
- **Disk-buffer retry across relaunch has no automated test.** It is runtime-validated for both
  signals.

## Tests

The simulator run is authoritative: it compiles against the real iOS SDK, including MetricKit.

```bash
cd Mobiles/ios/grafana-opentelemetry-ios
xcodebuild test \
  -scheme grafana-opentelemetry-ios \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/xcodebuild-dd
```

The macOS loop is faster but compiles MetricKit out (upstream's
`#if canImport(MetricKit) && !os(tvOS) && !os(macOS)` guard):

```bash
swift test
swift test --sanitize=thread --filter GrafanaOtelSessionSamplingTests
```

The package tests are not reachable through the app project.
`xcodebuild test -project QuickPizzaIos.xcodeproj -scheme GrafanaOpenTelemetryIOS` fails with
"Scheme GrafanaOpenTelemetryIOS is not currently configured for the test action", because Xcode
generates that scheme from the package product only.

`swift-tools-version:6.2` needs Xcode 26 or later. Validation evidence:
[session validation](../session-validation/README.md).

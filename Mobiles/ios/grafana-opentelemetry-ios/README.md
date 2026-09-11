# Grafana OpenTelemetry iOS

This local Swift package is the Grafana OpenTelemetry iOS composition spike. It is not published
and is not yet a supported SDK. QuickPizza consumes it as a local package reference while the
separate repository and release setup are agreed.

The package owns Grafana-oriented startup defaults and delegates all SDK behaviour to
[`opentelemetry-swift`](https://github.com/open-telemetry/opentelemetry-swift) and
[`opentelemetry-swift-core`](https://github.com/open-telemetry/opentelemetry-swift-core). It returns
the upstream providers, so application instrumentation continues to use standard OpenTelemetry APIs.

## Requirements

This package supports **iOS only**, and imposes no requirement of its own beyond what upstream
already requires, so adopting it never narrows what an iOS app could otherwise target.

- **Platform** — iOS 13, the floor declared by `opentelemetry-swift`, the binding upstream
  dependency. (`opentelemetry-swift-core` goes lower, to iOS 12, but the higher of the two binds.)
- **Toolchain** — `swift-tools-version:6.0`, the same as both upstream packages, so the package
  builds in **Swift 6 language mode** exactly as they do. That is stricter than a consumer still
  building in Swift 5 language mode, which is a property of the consumer, not of this package.
- **Upstream versions** — `opentelemetry-swift` `2.5.2` and `opentelemetry-swift-core` `2.5.1`,
  required as `.upToNextMinor(from:)`. That matches the requirement the Frontend Observability app
  page gives customers: upstream has shipped breaking work in *minor* releases — a session-recording
  refactor, the `SessionConfig` API this package calls, and a Swift 6 toolchain requirement — while
  patches have been bug fixes only. `2.5.2` is a floor rather than a preference: `requeueOnFailure`
  does not exist before it, and without that argument disk buffering cannot be configured correctly
  (see below).

**iOS is the supported platform.** macOS appears in `platforms` for one reason only: upstream's
exporter, resource, session and instrumentation products all require macOS 12, so without it the
`swift` CLI has no host platform and `swift build` / `swift test` cannot resolve. Treat macOS as a
host for the command-line toolchain, not as a supported target. Nothing else is declared — upstream
also supports tvOS, watchOS and visionOS, but this package is neither built nor tested for them.

One consequence is worth knowing: MetricKit sits behind upstream's own
`#if canImport(MetricKit) && !os(tvOS) && !os(macOS)` guard, so a macOS host build compiles it out.
`swift test` therefore does not exercise the MetricKit path; the simulator run does. See
[Tests](#tests).

The two exclusions in that guard are not the same kind of thing, which is worth knowing before
anyone tries to "fix" it. `MetricKit.framework` ships in the tvOS SDK, so `canImport(MetricKit)` is
true there, but every type is `API_UNAVAILABLE(tvos, watchos)` — the `!os(tvOS)` term is what makes
the code compile at all. macOS is different: everything upstream touches is available there
(`MXMetricManager` and `MXMetricManagerSubscriber` at macOS 12, `MXMetricPayload` at 10.15), and
upstream even annotates its own type `@available(iOS 13.0, macOS 12.0, macCatalyst 13.1,
visionOS 1.0, *)` — an annotation the `!os(macOS)` term makes unreachable. So the macOS exclusion is
an upstream scoping choice, not a platform limitation. watchOS needs no term because MetricKit is
absent from that SDK entirely.

Verified on Xcode 26.6 with Swift 6.3.3, on the macOS host and against an iOS 26.5 simulator.

```swift
let runtime = try GrafanaOtel.initialize(
    configuration: try GrafanaOtelConfiguration(
        otlpEndpoint: URL(string: "https://collector.example/otlp/app-key")!,
        // No default: a package cannot know which hosts you own.
        firstPartyHosts: ["api.my-app.example"],
        serviceVersion: "1.4.0",
        deploymentEnvironment: "production"
    )
)

let tracer = runtime.openTelemetry.tracerProvider.get(
    instrumentationName: "com.example.app",
    instrumentationVersion: "1.0.0"
)
```

Call `initialize` once, early in app startup, on the **main thread**. Called off-main it emits a
diagnostic rather than trapping, because the deadlock only occurs when the main thread is itself
waiting on that work. The upstream default resource
provider calls `DispatchQueue.main.sync` for device and OS attributes, so initializing from a
background queue while the main thread is blocked deadlocks.

Initialization is process-wide. The first call creates the runtime; later calls return that same
instance rather than registering a second set of providers, exporters and `URLSession` swizzles.
Concurrent callers block until the first call finishes and then receive its runtime. If startup
fails, the package does not retry in that process, because upstream setup may already have
registered global state — restart the process after correcting the configuration.

Treat the returned ``GrafanaOtelRuntime`` as process-lifetime. After `shutdown()`, restart the
process before initializing telemetry again.

## Why this package exists on iOS

`opentelemetry-swift` has **no assembled RUM agent**. There is no `OpenTelemetryRum` and no
`OpenTelemetryRumInitializer`: upstream ships providers, OTLP exporters, session processors and
instrumentations as separate pieces, and leaves it to each app to wire them together in the right
order. This package does that wiring once, with Grafana's defaults, and hands back a runtime handle
so an app does not have to rediscover the ordering rules below.

## Package boundary

The package owns only startup configuration and assembly that is specific to the Grafana
distribution:

- the OTLP endpoint, its signal paths, and export headers;
- the service and additional resource attributes;
- session inactivity, maximum lifetime, and cold-start restore behaviour;
- the HTTP semantic convention, fixed at the stable attribute names;
- which hosts receive W3C trace-context headers;
- disk buffering, its directory, and its backup policy;
- excluding its own collector origin (host **and** port) from automatic HTTP tracing;
- sanitising the request URL recorded on HTTP spans;
- the order the upstream pieces are installed in.

It does **not** define Grafana tracer, span, logger, event or meter APIs. `GrafanaOtelRuntime`
exposes upstream types only.

No `MeterProvider` is registered. Faro OTLP ingest currently accepts logs and traces only, so
metrics are left off rather than exported to a route that rejects them. This is an ingest
constraint, not a Swift SDK limitation: `opentelemetry-swift-core` `2.5.1` does ship a metrics SDK.

### Install order

The order in `GrafanaOtel.install` is load-bearing, and getting it wrong fails silently rather than
loudly:

1. The diagnostics handler, so problems in the later steps are observable at all.
2. The session manager. `SessionSpanProcessor()` and `SessionLogRecordProcessor(nextProcessor:)`
   resolve `SessionManagerProvider.getInstance()` in their initializers, and that call *lazily
   creates* a default manager (30-minute timeout) if nothing has registered one. A later
   `register` does not fix a processor that already captured the default.
3. The tracer provider, before any instrumentation is constructed.
4. The logger provider, before `SessionEventInstrumentation.install()`.
5. The instrumentations last. `URLSessionInstrumentationConfiguration.init` and
   `MetricKitConfiguration.init` resolve a concrete `Tracer`/`Logger` from the globals **at
   construction time**, so anything built before registration is permanently wired to the no-op
   provider and drops all data with no error.

## Configuration defaults

| Setting | Default |
| --- | --- |
| `otlpEndpoint` | Required; no default |
| `firstPartyHosts` | Required; no default |
| `serviceVersion` | Not set by this package; upstream's default resource still contributes a bundle-derived `"<short version> (<build>)"` value |
| `deploymentEnvironment` | Not set |
| `resourceAttributes` | Empty; the only route to `service.name` / `service.namespace` |
| `headers` | Empty |
| `sessionInactivityTimeout` | 15 minutes |
| `sessionMaxLifetime` | 4 hours |
| `restorePersistedSession` | `false` (new session on each cold start) |
| `diskBuffering` | `.enabledInDefaultDirectory` |
| `instrumentation` | `URLSession`, session events and MetricKit all enabled |

`otlpEndpoint` is required and must be valid. There is no mode that installs the SDK without an
exporter: this package exists to export, and a half-installed telemetry stack that silently produces
nothing is worse than an error at the call site. If your app can run without telemetry, decide that
before calling `initialize` rather than passing a placeholder endpoint — an unreachable endpoint
still creates exporters and queues failed telemetry (on disk for traces and, after the first
attempt, in memory for logs).

There is no `serviceName` or `serviceNamespace` setting. Upstream's default resource always derives
a `service.name` from the bundle name, and ingest maps that to the app-name column — backfilling the
*registered* app name only when the attribute is absent or an `unknown_service*` placeholder. The
package therefore **removes** it, so the app you registered is the app the product shows, and offers
no setting to put one back.

When you do need a service identity — exporting to somewhere with no registered app, such as the
general Grafana Cloud OTLP gateway, where `service.name` and `service.namespace` are the only
identity labels — pass them through `resourceAttributes`. An explicit `service.name` there is kept
as given rather than removed.

`deploymentEnvironment` is recorded as `deployment.environment.name`, the current semantic
convention. Without it, production and staging telemetry share one app with no way to separate them.

The endpoint must be an absolute `http://` or `https://`
URL with no query string or fragment, and must be the OTLP **base** URL rather than one already
ending in `/v1/traces`, `/v1/logs` or `/v1/metrics`; HTTP remains useful for simulator loopback
tests while production endpoints should use HTTPS. Each `firstPartyHosts` entry must be a bare
host, because an entry carrying a scheme, port or path would match nothing and silently stop
trace-context injection. Header names must be visible ASCII and
header values may contain tabs or visible ASCII. Resource attribute keys must be 1–255 printable
ASCII characters, because upstream's `Resource(attributes:)` silently discards **every** attribute
when any single key is invalid.

Batch and transport tuning is deliberately not exposed, so there is no untested configuration
surface to support. The upstream defaults apply — 5-second schedule delay, 30-second export timeout,
2048 queue, 10-second HTTP timeout, gzip — with one exception the package sets itself: the export
batch is 512 records straight to the network but **128 when buffering to disk**, because persistence
JSON-encodes a whole batch and then applies a 256 KiB cap, and an oversized write fails silently.

### Endpoint, headers and the environment

`otlpEndpoint` is the OTLP **base** URL. The upstream exporters use their endpoint verbatim, so the
package appends `/v1/traces` and `/v1/logs` itself, normalising a trailing slash on the way.

Configured `headers` are merged with `OTEL_EXPORTER_OTLP_HEADERS` and win on a case-insensitive name
match. The environment variable is parsed here rather than upstream, and splits on the *first* `=`
only — upstream requires exactly two `=`-separated components, which silently drops every base64
value carrying `=` padding, that is, every `Basic` credential. The merge exists because the upstream exporter treats `envVarHeaders` and
`OtlpConfiguration.headers` as mutually exclusive — whenever `envVarHeaders` is non-nil,
`config.headers` is never read — so configured headers would otherwise be droppable by an
environment variable. Duplicate names are removed, because the exporter comma-appends repeated
header names rather than replacing them.

`OtlpConfiguration` itself is not reachable from this package: it lives in the
`OpenTelemetryProtocolExporterCommon` target, which `opentelemetry-swift` does not expose as an SPM
product. Importing an undeclared transitive target module would work today but is not a dependency
this package is willing to take, which is why transport timeout and compression are not
configurable here.

### HTTP semantic conventions

Not configurable. The automatic HTTP instrumentation always emits the **stable** attribute names —
`http.request.method`, `url.full`, `http.response.status_code` — never upstream's default of the
pre-stabilisation `http.method` / `http.url` / `http.status_code`. Ingest reads the stable names
first and falls back to the legacy ones, so there is no case where a new app benefits from the
deprecated set, and one fewer knob is one fewer untested combination. A `customizeURLSession`
callback that sets `semanticConvention` is overridden.

### Recorded request URLs

The upstream instrumentation records the request URL from `absoluteString`, so a query string, a
fragment, or credentials embedded in a URL would be exported verbatim. This package always rewrites
that attribute with a sanitised value — query, fragment, user and password removed — and does so
after any `customizeURLSession` callback, so a caller cannot put the raw value back. The attribute written is
`url.full`, which is what the stable convention records.

### Disk buffering

On by default, with different guarantees by signal. Span batches are retried from disk, survive
relaunch, and can be delivered after connectivity returns. Log batches are persisted only until
their first export attempt. The pinned `OtlpHttpLogExporter` reports success before the HTTP
response arrives, so the persistence decorator removes the disk copy; if the request later fails,
the exporter requeues those logs in memory only. Logs — including MetricKit diagnostics — therefore
do not have durable offline retry after an attempt has started.

The log queue still narrows the termination-loss window before that first attempt, while the record
is waiting on disk. It must not be treated as the same offline-delivery guarantee as trace
buffering.

The default location is a package-owned directory under Application Support, so the system does not
reclaim it under storage pressure, and the package sets `isExcludedFromBackupKey` on it. That flag
matters: the queue holds full trace and log payloads — URLs, error messages, user attributes — which
would otherwise outlive the local retention window inside a device backup.

`.enabled(storageURL:)` takes a directory you own instead. The package creates it and its two signal
subdirectories but does **not** touch its backup policy, because silently changing that on someone
else's directory would be a surprising side effect. Set `isExcludedFromBackupKey` yourself.

### Trace-context propagation

Upstream injects `traceparent`, `tracestate` and `baggage` into every request it instruments,
including third-party hosts. `firstPartyHosts` narrows that to the hosts you name, and it has no
default: a package cannot know which hosts you own, so the choice is part of setup rather than
something inherited.

Matching is an **exact**, case-insensitive host comparison. `["example.com"]` does **not** authorise
`api.example.com` — list every host you want, subdomains included. That is deliberate: a host is
trusted only because someone listed it, which also means a look-alike domain can never match by
suffix. An empty array is valid and propagates to nothing, at the cost of no trace connecting to a
backend.

A `customizeURLSession` callback may narrow this further but cannot widen it: the list is
re-asserted after the callback runs.

## Known limitations

These are properties of the pinned upstream release, not of this package's configuration:

- **No lifecycle or screen-view instrumentation.** Nothing upstream emits app-start, foreground,
  background, `screen.view` or jank signals, so they stay app-owned and hand-written.
- **Crash and hang reporting is MetricKit-only**, so it is delivered on Apple's schedule, typically
  the next day. There is no signal handler and no next-launch upload, so this package cannot report
  a crash promptly after it happens.
- **No backoff and no reliable delivery signal.** The OTLP/HTTP exporters have no
  `Retry-After` handling. Buffered traces retry from disk on the persistence schedule, while failed
  log requests are requeued in an unbounded in-memory queue that dies with the process.
  `OtlpHttpLogExporter.export` always reports success. A wrong ingest URL therefore looks identical
  to a working one from inside the app — only the diagnostics handler reveals a 404 or 401.
- **Nothing flushes on background or termination.** Use `GrafanaOtelRuntime.forceFlush()` from your
  own lifecycle hooks — but not on the main thread. It blocks on synchronous OTLP trace export, and
  a stalled collector can hold the caller for the exporter's 10-second transport timeout per pending
  batch. For logs it only guarantees the records left the batch queue: `OtlpHttpLogExporter.export`
  reports success without waiting.
- **`LoggerProviderSdk` has no flush or shutdown**, which is why the runtime retains the log
  processors. It retains the ones *behind* the session decorator on purpose:
  `SessionLogRecordProcessor.forceFlush` and `.shutdown` return `.success` without forwarding to
  their `nextProcessor`, so flushing through the decorator would export nothing.
- **Session inactivity is signal-based, not interaction-based.** `SessionSpanProcessor.onStart`
  extends the session on every span, and automatic HTTP spans include background traffic, so the
  15-minute window means "15 minutes with no span and no log" rather than Faro's user-interaction
  rule.
- **`URLSession` instrumentation cannot be uninstalled** and only one configuration can win per
  process. That is why the package installs it and exposes `customizeURLSession` instead of letting
  the app construct a second instance, which would chain swizzles and double-instrument.
- **Disk buffering has asymmetric delivery guarantees.** Trace retry from disk has been
  runtime-validated, but no automated test exercises the persisted path end to end. Log persistence
  cannot provide durable offline retry at the pinned upstream version:
  `OtlpHttpLogExporter.export` reports success before the response arrives, so the persistence
  decorator deletes the batch and a later failure is requeued in memory only. The package creates
  both signal directories up front, keeps them out of device backups, shrinks export batches to stay
  under the 256 KiB cap, and sets trace `requeueOnFailure: false` so the disk queue owns trace retry.
- **Buffering delays every signal.** Records become readable to the exporter after roughly
  4.75 seconds and then export on an adaptive 1–20 second cycle. Pass `.disabled` if you would
  rather have prompt delivery and accept losing whatever is queued at termination.

## Tests

The simulator run is authoritative, because it compiles against the real iOS SDK and so exercises
the MetricKit path as shipped:

```bash
cd Mobiles/ios/grafana-opentelemetry-ios
xcodebuild test \
  -scheme grafana-opentelemetry-ios \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/xcodebuild-dd
```

`swift build` and `swift test` also work from the same directory and are much faster, which is what
the macOS entry in `platforms` is there for:

```bash
swift test
```

The two runs are not equivalent. On a macOS host `MetricKitInstrumentation` compiles to an empty
module, so `swift test` covers the configuration, mapping, propagation, `URLSession` and
initialization tests but skips the MetricKit branch. Use it for the fast loop and the simulator run
before trusting a result.

The package's tests are not reachable through the app project. Xcode generates a project-level
scheme from the package *product* only, and that scheme has no test action, so
`xcodebuild test -project QuickPizzaIos.xcodeproj -scheme GrafanaOpenTelemetryIOS` fails with
"Scheme GrafanaOpenTelemetryIOS is not currently configured for the test action".

See [the spike decision and validation note](../../docs/GRAFANA_OPENTELEMETRY_IOS.md) for the
proposed production location, package boundary, migration, removal, and remaining gates.

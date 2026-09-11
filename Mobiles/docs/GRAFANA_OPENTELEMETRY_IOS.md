# Grafana OpenTelemetry iOS

**Status:** Experimental local package. It is not published or supported for production use.

This package follows the composition direction: customers keep instrumenting through standard
OpenTelemetry APIs, and a Grafana package adds setup, defaults and Grafana-specific instrumentation
around the upstream SDK without introducing a Grafana telemetry API.

## Placement decision

The runnable spike lives in `Mobiles/ios/grafana-opentelemetry-ios` and is consumed by the
existing QuickPizza iOS app as a local Swift package reference. This gives the package a real
application and build without creating an empty repository or treating the demo repository as its
permanent home.

The package sits beside `QuickPizzaIos.xcodeproj` rather than inside `Mobiles/ios/QuickPizzaIos/`,
because the app target uses a file-system-synchronized group over that folder: sources placed there
would be compiled both as package targets and as app sources.

The demo proves the package boundary but is not the permanent source or release location. Generic
Swift SDK and instrumentation work belongs upstream in
[`opentelemetry-swift`](https://github.com/open-telemetry/opentelemetry-swift), while build-time
symbol upload for mobile stays outside this runtime package. The final Grafana-owned runtime
location, package identity, release ownership, automation, and supported upstream version window
require agreement before the package is extracted or published.

The proposed name is **Grafana OpenTelemetry iOS**, with `GrafanaOtel.initialize(...)` as the
startup entrypoint. The local directory name is not a published package identity.

The spike uses `opentelemetry-swift` `2.5.2` with `opentelemetry-swift-core` `2.5.1`, required as
`.upToNextMinor(from:)` — the same versions and the same operator the Frontend Observability app page
gives customers, so the package and the product's own instructions cannot drift apart. `2.5.2` is a
floor, not a preference: `requeueOnFailure` does not exist before it, and without that argument the
disk-buffering path cannot be configured correctly. Minor releases are excluded because upstream has
shipped breaking work in them; patches have been bug fixes only. The app's project requirement and
its committed `Package.resolved` were both moved to match.

The package declares **iOS only**, at iOS 13 — the floor `opentelemetry-swift` itself declares — and
`swift-tools-version:6.0`, matching both upstream manifests. Scope and floor are separate decisions
here: the scope is iOS because that is the only platform this spike builds and tests for, while the
floor is upstream's rather than a higher one a demo app would suggest, because a Grafana package
that raised the floor would silently disqualify iOS apps the upstream SDK supports.

macOS is declared alongside it, at upstream's `.macOS(.v12)` floor, purely as a host platform:
upstream's exporter, resource, session and instrumentation products all require macOS 12, so without
it the `swift` CLI cannot resolve the package and `swift build` / `swift test` are unavailable. It is
the minimum needed to keep a command-line loop, not a claim of macOS support. Nothing beyond those
two is declared.

The cost of that host entry is that `swift test` does not cover everything: MetricKit sits behind
upstream's `#if canImport(MetricKit) && !os(tvOS) && !os(macOS)` guard and compiles out on a macOS
host, so the simulator run remains the authoritative one.

That guard's two terms have different causes, and only one is a real limitation. `!os(tvOS)` is
required: `MetricKit.framework` ships in the tvOS SDK so `canImport` is true, but every type is
`API_UNAVAILABLE(tvos, watchos)`. `!os(macOS)` is not required — the full surface upstream uses is
available on macOS 12, and upstream annotates its own instrumentation
`@available(iOS 13.0, macOS 12.0, macCatalyst 13.1, visionOS 1.0, *)`, which that term makes
unreachable. It is an upstream scoping decision. This package mirrors the guard rather than
diverging from it, so the macOS gap in `swift test` is inherited, not chosen here.

Both are declared with `exact:` in the package manifest: the package supports one tested upstream
release at a time rather than advertising a range it has not exercised. The cost is real and worth
stating:
`exact:` is viral for consumers, and if the app's requirements are ever moved past `2.5.x` the
package manifest has to move in the same commit or workspace resolution fails.

## Why this package exists

`opentelemetry-swift` ships no assembled RUM agent. There is no `OpenTelemetryRum`, no
`OpenTelemetryRumInitializer`, no autoconfigure module, and no SDK facade type. Upstream ships
providers, OTLP exporters, session processors and instrumentations as independent pieces, and leaves
each app to wire them together in the right order.

That is what this package is for. It owns the assembly and its ordering once, applies Grafana's
defaults, and hands back a runtime handle — so an app gets a working RUM setup from one call instead
of rediscovering the ordering rules recorded below, several of which fail silently when they are got
wrong. It is why this package is more than a thin configuration shim, and it is worth recording as a
platform finding rather than an implementation detail.

## Package boundary

The package owns only startup configuration and assembly that is specific to the Grafana
distribution:

- the OTLP endpoint — required, and validated — plus its per-signal paths and export headers;
- the resource, including removing the bundle-derived `service.name`;
- session inactivity, maximum lifetime, and cold-start restore behaviour;
- the HTTP semantic convention, fixed at the stable attribute names;
- which hosts receive W3C trace-context headers;
- disk buffering, its directory, and its backup policy;
- excluding its own collector origin from automatic HTTP tracing;
- sanitising the request URL recorded on HTTP spans;
- the retry ownership split between the disk queue and the HTTP exporters;
- the order in which the upstream pieces are installed.

It delegates all SDK behaviour to upstream and returns `GrafanaOtelRuntime`, which exposes the
registered `TracerProviderSdk` and `LoggerProviderSdk`, the standard OpenTelemetry API entry point,
and a flush/shutdown path. It does **not** define Grafana tracer, span, logger, event or meter APIs.

The app still owns application-specific behaviour: the runtime config UI, the debug-only console
span exporter, business instrumentation, screen-view events, and the app's instrumentation scope.

No `MeterProvider` is registered. Faro OTLP ingest currently accepts logs and traces only, so
metrics are left off rather than exported to a route that rejects them. This is an ingest
constraint, not a Swift SDK limitation — `opentelemetry-swift-core` `2.5.1` does ship a metrics SDK.

### Install order

The install order is load-bearing, and every way of getting it wrong fails silently rather than
loudly. This is the part of the package with the least upstream guidance:

1. The upstream default resource, built *before* the initialization lock is taken. Upstream's
   device and OS resource providers block on the main queue, so building the resource under the lock
   would let a main-thread status read deadlock against a background initializer.
2. The diagnostics handler, so failures in later steps are observable at all.
3. The session manager. `SessionSpanProcessor()` and `SessionLogRecordProcessor(nextProcessor:)`
   resolve `SessionManagerProvider.getInstance()` in their initializers, and that call *lazily
   creates* a default manager with a 30-minute timeout if nothing has registered one. Registering
   afterwards does not repair a processor that already captured the default.
4. Everything that can fail: both disk-buffering directories, the exporters, and both pipelines.
   None of the remaining steps throw, so a failure can never leave a globally registered provider
   with a live batch worker that no runtime handle can flush or shut down.
5. The providers, registered globally — tracer then logger.
6. `SessionEventInstrumentation.install()`, after the logger provider, so its queued session events
   do not reach the no-op default logger.
7. The instrumentations last. `URLSessionInstrumentationConfiguration.init` and
   `MetricKitConfiguration.init` resolve a concrete `Tracer`/`Logger` from the global
   `OpenTelemetry.instance` **at construction time**. Anything built before registration is
   permanently wired to the no-op provider and drops all data with no error.

Steps 1 and 4 exist because of review findings, not because upstream documents them.

### Instrumentation extension

Swift has no `ServiceLoader` and upstream has no instrumentation-discovery mechanism, so there is no
Swift analogue of publishing an instrumentation as a separately discovered module. A Grafana
instrumentation would either be a span/log processor supplied through the package's experimental
options, or code the package installs itself.

`URLSessionInstrumentation` constrains this: it swizzles globally in its initializer with no
idempotency guard and no uninstall, and only one configuration can win per process. Constructing a
second instance chains implementations and double-instruments every request. That is why the package
installs it and exposes a `customizeURLSession` hook rather than letting the app build its own.

## Add and remove

The demo adds the local package reference and replaces `OTelService`'s hand-written provider,
exporter, session and instrumentation setup with `GrafanaOtel.initialize`. Existing application
instrumentation is unchanged: `Tracer.swift`, `Logger.swift` and `AppEvents.swift` still receive
`OpenTelemetryApi` types and were not edited.

To remove Grafana OpenTelemetry iOS:

1. Remove the `GrafanaOpenTelemetryIOS` product dependency from the app target and the
   `XCLocalSwiftPackageReference` from the project's package references.
2. Replace the `GrafanaOtel.initialize` call with direct upstream setup: build a
   `TracerProviderSdk` and `LoggerProviderSdk`, register them on `OpenTelemetry`, and construct the
   desired non-Grafana exporters and instrumentations.
3. Keep the upstream package products the app already links, and add any the package was providing
   transitively.
4. Delete `Mobiles/ios/grafana-opentelemetry-ios`.
5. Leave application tracer, logger, event and context-propagation calls unchanged.

This spike verifies the source boundary, but the removal path still needs an automated build or
fixture before the portability gate can be marked complete.

## Run locally

```bash
cd Mobiles/ios/grafana-opentelemetry-ios
xcodebuild test \
  -scheme grafana-opentelemetry-ios \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/xcodebuild-dd

cd ..
xcodebuild -project QuickPizzaIos.xcodeproj -scheme QuickPizzaIos \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
bash Scripts/sim-run.sh
```

The app reads its normal `Config.xcconfig`. See [`Mobiles/ios/README.md`](../ios/README.md) for
configuration and simulator instructions, and the
[package README](../ios/grafana-opentelemetry-ios/README.md) for the configuration surface.

Two command-line notes specific to Swift packages:

- `swift build` and `swift test` work from the package directory and are much faster, but on a macOS
  host `MetricKitInstrumentation` compiles to an empty module, so they skip the MetricKit branch.
- The package's tests are not reachable through the app project. Xcode generates a project-level
  scheme from the package *product* only, and that scheme has no test action, so
  `xcodebuild test -project QuickPizzaIos.xcodeproj -scheme GrafanaOpenTelemetryIOS` fails with
  "Scheme GrafanaOpenTelemetryIOS is not currently configured for the test action".

## Validation results

All runs below used an iPhone 17 Pro simulator on iOS 26.5, Xcode 26.6 and Swift 6.3.3, with the
local QuickPizza backend and a host-side HTTP receiver. The receiver records request paths, sizes
and decompressed bodies; it is not a Faro Collector, so these runs prove the client export path and
not product ingest.

### Unit and mapping coverage

On September 10, 2026, the package's tests passed both on an iOS 26.5 simulator
(`xcodebuild test`, `** TEST SUCCEEDED **`) and on the macOS host (`swift test`). The simulator run
is the one that compiles the MetricKit path against the real iOS SDK; `swift build` resolved the
same pinned upstream versions the app uses, so the fast loop and the authoritative run agree on
dependencies.

Coverage is split so that the configuration-to-SDK mapping can be asserted without registering
process-wide providers:

- configuration validation, including endpoint scheme/query/fragment rules, blank identity values,
  resource-attribute key rules, header character rules and session-timeout ordering;
- the resolved plan: resource precedence, signal-path construction, header merge precedence and
  deduplication, environment-variable header parsing, session mapping, semantic-convention mapping
  and collector-origin exclusion;
- the trace-propagation allowlist, including subdomain matching and suffix look-alikes;
- the single-initialization guard, including concurrent callers, remembered failure and re-entry;
- the `URLSession` configuration the package assembles: collector-origin exclusion, the propagation
  policy, the semantic convention, and the fact that a caller's customization can narrow those but
  not widen them;
- one end-to-end installation test that registers real upstream providers and asserts that a span
  and a log record created through the standard API carry the Grafana resource and the same
  `session.id`, that the session processors captured the *configured* session manager rather than a
  lazily created default, that session lifecycle records are emitted, that the diagnostics handler
  is installed, that a second `initialize` returns the identical runtime, and that `forceFlush` and
  `shutdown` reach the processors behind the session decorator.

The last two were added after review: without them, collapsing the flush split or deleting the
collector exclusion left the suite green. Both changes are now caught (4 and 2 failing tests
respectively when reintroduced deliberately).

### Debug runtime result

On September 10, 2026, the debug app was installed and cold-started with the OTLP endpoint pointed
at a host-side receiver on `http://localhost:8002/otlp/<appKey>` and the backend on
`http://localhost:3336`.

The receiver accepted gzip-compressed OTLP for both supported signals:

```text
POST /otlp/<appKey>/v1/logs   wire=885 decoded=1958 enc=gzip
POST /otlp/<appKey>/v1/traces wire=797 decoded=1394 enc=gzip
```

The decompressed log payload carried the full resource — `service.name=quickpizza-ios`,
`service.namespace=quickpizza`, `service.version`, `service.build`,
`deployment.environment=production` — merged over the upstream default resource (`os.*`,
`device.*`, `telemetry.sdk.*`). It contained a `session.id`, and a later launch produced a
`session.end` record with `session.previous_id` under the `io.opentelemetry.sessions` scope,
confirming the session lifecycle events and the cold-start "new session" rule.

The trace payload carried automatic `URLSession` client spans under the upstream `NSURLSession`
scope with `session.id` stamped on the span. A re-run after the field-guide alignment confirmed the
new defaults on the wire: `url.full` and `http.request.method` present, `http.url` and `http.method`
absent, and `deployment.environment.name` on the resource of both signals.

### Connected-trace result

The app injected W3C trace context into its backend requests, and the identifiers it injected are
the ones it exported:

```text
GET /api/tools  traceparent=00-7f41a18be35852e1f0fa098685eda9fa-dd3f9e703a8868c4-01
GET /api/quotes traceparent=00-f133b98946502a51fa1319adbf7bfaee-feea95acc3847fc0-01
```

Both 16-byte trace IDs and both 8-byte span IDs were then found verbatim in the exported OTLP trace
payload. That establishes the client half of a connected mobile-to-backend trace: the span the app
exports is the parent the backend receives. The backend half is the existing QuickPizza tracing and
is not re-proven here.

### Re-confirmed after the API changes

The runtime results above were first captured before several public-API decisions landed — the
required endpoint, the removal of `serviceName`/`serviceNamespace`, the fixed semantic convention,
and `firstPartyHosts` replacing the propagation enum. They were re-run on September 11, 2026 on the
same simulator and the wire output was identical: `url.full` and `http.request.method` present with
`http.url` and `http.method` absent, `deployment.environment.name`, `session.id`, `service.name`,
`service.namespace` and `service.build` on both signals, clean request URLs with no query string,
and both injected `traceparent` trace ids present in the exported spans.

That last point is the one the changes could have broken: `service.name` now arrives through
`resourceAttributes` rather than a dedicated setting, and trace context now matches the first-party
host exactly rather than by policy. Both produce the same telemetry as before.

### Buffered delivery result

On September 10, 2026, disk buffering was exercised on the same simulator by taking the receiver
down, running the app so records failed to export, killing the app, restoring the receiver, and
relaunching.

The queue behaved as intended. A trace batch was written to
`Library/Application Support/com.grafana.opentelemetry.ios/traces/`, survived the kill, and was
delivered after relaunch — then removed from the queue. The two delivered trace payloads carried
two different `session.id` values against a constant `device.id`, which is what shows the queued
batch kept the session it was recorded in rather than being re-stamped with the new one.

The directory carried `com.apple.metadata:com_apple_backup_excludeItem`, so the backup exclusion the
package sets is in force.

One asymmetry showed up exactly as documented: only traces queued. Log records did not, because
`OtlpHttpLogExporter.export` reports success before its response arrives, so the disk queue deletes
them immediately. That is the reason logs keep `requeueOnFailure: true` while traces do not, and it
is a live demonstration of the caveat rather than a defect in this package.

### Release runtime result

The same checks were repeated with a `Release` build, which is where Swift optimization and
dead-code stripping apply.

The release build succeeded, installed, cold-started, and exported both signals to the receiver
(`POST /otlp/<appKey>/v1/traces wire=794 decoded=1393 enc=gzip`, plus a logs payload). The
traceparent identifiers injected into the backend requests were again present in the exported trace
payload, and the resource carried the expected `os.*` and `device.*` attributes — which matters
because upstream's `DefaultResources` discovers its providers with `Mirror`, the one reflective
path in the startup sequence. There is no `ServiceLoader` and no keep-rule equivalent to maintain.

### Three defects this validation caught

Each was found by running the app rather than by reading code, and each is recorded because it is
the kind of thing a reference kit is supposed to get right once for everyone:

- **Collector exclusion must match host *and* port.** Excluding the collector by host alone
  suppressed every backend span during local development, because the receiver and the backend were
  both `localhost`. The package now compares scheme-normalised host and port, and a regression test
  covers the local-development case.
- **A rejected endpoint fails loudly, not silently.** Startup originally abandoned initialization
  without saying why, so a mistyped endpoint looked identical to a working one from inside the app.
  `OTelService` now validates the endpoint before calling the package, reports the specific reason
  through both its own log and the app's startup log, and records it on `otlpRejectionReason` so the
  state is inspectable rather than guessed at. It does **not** fall back to a telemetry stack with
  export disabled: the endpoint is required, and a rejected one means no SDK for that process — see
  [There is no install-without-exporting mode](#there-is-no-install-without-exporting-mode) for why
  that trade was taken and what it costs.
- **Log flushing must bypass the session decorator.** `SessionLogRecordProcessor.forceFlush` and
  `.shutdown` return `.success` without forwarding to their `nextProcessor`, so flushing through it
  exports nothing. `GrafanaOtelRuntime` therefore retains the processors behind the decorator.

## Alignment with the iOS field guide

The Frontend Observability field guide *OpenTelemetry Swift (iOS) with Frontend Observability* is the
normative description of this ingest path. It is maintained outside this repository, so it is named
rather than linked. The package was reviewed against it and six things changed as a result. They are recorded here because each is a default that would otherwise
look arbitrary:

| Guide requirement | What the package now does |
| --- | --- |
| `createdRequest` must rewrite the recorded URL — upstream records `absoluteString`, so query values and embedded credentials would be exported verbatim | Always rewrites it with query, fragment, user and password removed, after any caller callback, on whichever attribute the convention emits |
| `shouldInjectTracingHeaders` must be restricted to hosts you control; it defaults to true | `firstPartyHosts` has **no default**, so the decision cannot be skipped |
| `semanticConvention: .stable` — new apps should not start on deprecated names | Fixed at `.stable`, with no way to configure it |
| `deployment.environment.name` | Uses that key, not the older `deployment.environment` |
| `service.name` should be removed so ingest uses the registered app identity | Always removed; there is no setting to put one back, and `resourceAttributes` is the escape hatch |
| `requeueOnFailure: false` on the trace exporter under persistence, `true` for logs | Exactly that split, which is why `2.5.2` is the floor |

Nine other requirements the guide calls load-bearing were already satisfied: both session processors,
the Faro session values, `SessionEventInstrumentation` after the logger provider, collector-host
exclusion, no meter provider, a feedback handler, creating the persistence directories, the
main-thread requirement, and avoiding the `MetricKit`/`OpenTelemetryApi` `Logger` ambiguity.

Two guide points remain unaddressed and are listed as gates below: the 256 KiB persisted-batch cap
(this package does not expose `maxExportBatchSize`), and the storage-directory trade-off between
`cachesDirectory` being purgeable and `applicationSupportDirectory` being backed up.

### Trace propagation is a host list, not a policy type

An earlier revision modelled this as a `GrafanaOtelTracePropagation` enum with an `allHosts` case
and suffix matching, so `example.com` also authorised `api.example.com`. It is now a plain
`firstPartyHosts: [String]` with exact, case-insensitive matching.

Three reasons. The enum duplicated `customizeURLSession`, which can already set
`shouldInjectTracingHeaders` — two routes to one upstream setting. `allHosts` existed only to
reproduce the upstream default this package exists to correct, so offering it was offering the
mistake. And suffix matching decided trust by string shape rather than by an explicit list, which is
the kind of rule that quietly authorises more than its author intended.

What survived is the part that earns its place: the parameter is still required, so the decision
cannot be skipped. What went is roughly 50 lines of enum, matcher and validation, and an 81-line
test file replaced by a tighter one.

The cost is that subdomains must be listed individually, and there is no supported way to propagate
to every host. Both are intended.

### There is no service-name setting

`serviceName` and `serviceNamespace` were removed from the configuration. Both were optional, both
defaulted to unset, and unset was the recommended value for this ingest path — a setting whose
correct value is "don't use it" is better expressed by not having it.

The package now always removes the bundle-derived `service.name` that upstream's
`ApplicationResourceProvider` adds, so ingest applies the registered app identity. The one case that
genuinely needs a service name — export to somewhere with no registered app, such as the general
Grafana Cloud OTLP gateway — goes through `resourceAttributes`, and an explicit `service.name` there
survives the removal.

That also resolves an inconsistency: `resourceAttributes` used to be documented as losable to the
package's own service attributes, which made it unusable as an override. Now the precedence is
simply that the caller's map wins for identity, and the package owns only `service.version` and
`deployment.environment.name`.

QuickPizza passes both through `resourceAttributes`, because the demo also runs against the legacy
gateway — so its emitted identity is unchanged.

### The HTTP semantic convention is not configurable

The package always emits the stable HTTP attribute names and provides no setting to change that.
Ingest reads the stable names first and falls back to the legacy ones, so a configurable convention
only ever let an app choose the deprecated set — and it cost three enum cases, a mapping function, a
per-convention attribute-key lookup in the URL sanitiser, and the tests for all of it. A
`customizeURLSession` callback that sets `semanticConvention` is overridden after it runs.

That also simplified the URL sanitiser: it writes `url.full` and nothing else, rather than choosing
keys per convention.

### There is no install-without-exporting mode

`otlpEndpoint` is non-optional. An earlier revision allowed `nil` to install the providers, sessions
and instrumentations with no exporter attached, which was convenient for local runs and wrong as a
product: it produced a telemetry stack that looked installed and silently emitted nothing, and it
put a branch through every pipeline in the package for a case the distribution does not support.

Requiring it removed four conditional paths and one class of silent failure. The cost is that a
malformed or absent endpoint now means no SDK at all rather than an SDK with export disabled, so
`OTelService` in the demo reports the reason and continues on upstream's no-op providers —
instrumentation still compiles and runs, it just produces nothing. That state also costs the demo
its debug-only console span exporter, because the exporter reaches the SDK through the package's
experimental options.

A placeholder endpoint is not a substitute: an unreachable endpoint still creates exporters and
queues failed telemetry (on disk for traces and, after the first attempt, in memory for logs).

### Disk buffering is on by default

Its guarantee differs by signal. Trace batches are retried from disk, survive relaunch, and can be
delivered after connectivity returns. Log batches are durable only until their first export attempt:
the pinned HTTP log exporter reports success before the response arrives, so persistence removes the
disk copy and a later network failure is requeued in memory only. Logs — including MetricKit
diagnostics — therefore have a smaller pre-export termination window, not durable offline retry.
Three decisions had to ship with buffering:

- **A directory that survives and is not backed up.** A caches directory can be evicted under
  storage pressure, losing the queue. A durable directory is normally included in device backups,
  and the queue holds full payloads, so the package uses Application Support and sets
  `isExcludedFromBackupKey`. A caller-supplied directory is left untouched.
- **A smaller export batch.** Persistence JSON-encodes a whole batch and then applies a 256 KiB
  cap, and an oversized write fails *silently*. `maxExportBatchSize` counts records, not bytes, so
  the package drops from 512 to 128 records whenever buffering is active.
- **Retry ownership.** Traces get `requeueOnFailure: false` so the disk queue owns retry. Logs keep
  `true`, but that retry is in-memory only after the persistence decorator removes the attempted
  batch; it does not survive relaunch.

The cost is latency: records become readable after roughly 4.75 seconds and export on an adaptive
1–20 second cycle. `.disabled` remains available for prompt delivery.

### Checked against the product's own setup instructions

The Frontend Observability app page now carries native iOS setup instructions. The package was
compared against the Swift they generate, and they agree on every substantive point: `service.name`
left unset so ingest applies the registered app name, `semanticConvention: .stable`, the
`createdRequest` rewrite of the recorded URL, the Faro session values, `SessionEventInstrumentation`
after the logger provider, excluding the collector host from tracing, retaining the MetricKit and
`URLSession` instances, no meter provider, and the `2.5.2` / `2.5.1` version pair.

Three differences, each deliberate:

- **Dependency operator.** Adopted from the product instructions: `.upToNextMinor(from:)` rather
  than the `exact:` pin this spike started with.
- **Trace-context propagation.** The product instructions leave
  `shouldInjectTracingHeaders` at its default, which injects into every instrumented request. The
  field guide calls restricting it load-bearing. This package resolves the disagreement by giving
  `firstPartyHosts` no default, so the choice is made explicitly at the call site rather than
  inherited from either source.
- **`PersistenceExporter`.** Not in the product's product list. This package takes it so disk
  buffering can be offered at all, and enables it by default with the signal-specific guarantees
  above.

## Known upstream limitations

These are properties of the pinned upstream release, not of this package's configuration. They are
what a RUM product needs and `opentelemetry-swift` does not yet provide:

| Capability | Status at the pinned version |
| --- | --- |
| Assembled RUM agent | None; this package owns the assembly |
| Lifecycle, screen-view and jank signals | Not available; app-owned |
| Crash and hang capture | MetricKit only, delivered on Apple's schedule |
| Offline buffering | A contrib decorator enabled by default; trace retry from disk is runtime-validated, while logs are durable only until their first export attempt |
| Export retry | Traces retry from disk on the persistence schedule; log failures are requeued in memory only |
| Background and termination flush | None; the caller must call `forceFlush` |

Additionally: `OtlpHttpLogExporter.export` always reports success, so a wrong ingest URL looks
identical to a working one from inside the app — only the diagnostics handler reveals a 404 or 401.
Session inactivity is signal-based rather than interaction-based, because
`SessionSpanProcessor.onStart` extends the session on every span and automatic HTTP spans include
background traffic.

## Validation status

- [x] The package compiles as a Swift package and is consumed by the runnable demo app.
- [x] Configuration validation has focused unit coverage.
- [x] Grafana defaults, additive resources, header policy, the first-party host list and
  collector-origin exclusion have focused mapping coverage.
- [x] The package returns upstream OTel runtime and API types.
- [x] Existing application instrumentation compiles without changes.
- [x] The demo cold-starts through the package in debug and release on an iOS 26.5 simulator.
- [x] Decoded OTLP logs and traces reach a local receiver from both build configurations.
- [x] Required session signals (`session.id`, `session.previous_id`, session lifecycle records) are
  present on spans and log records.
- [x] Client-side trace-context propagation is verified byte-for-byte against the exported spans.
- [ ] Run the app against Faro Collector and verify the required Mobile O11y signals and the
  Frontend Observability product paths.
- [ ] Verify an app-instrumented mobile HTTP span remains connected to the QuickPizza backend trace
  in Tempo.
- [ ] Automate the add/remove build using a supported non-Grafana provider.
- [ ] Agree the production repository, package identity, release owner and support window.
- [ ] Validate a released package from a separate consumer resolving it by URL and tag; a local path
  reference does not exercise real resolution.
- [ ] Decide whether Objective-C interop is required, or state that Swift-only is intentional.
- [ ] Add public-API stability checking before publishing a versioned release.
- [ ] Add background and termination flush hooks, and an observable export-health path beyond the
  diagnostics callback. `forceFlush` blocks the caller on synchronous OTLP trace export, so a hook
  cannot simply call it on the main thread.
- [x] Validate buffered delivery at runtime with a kill and relaunch.
- [ ] Cover the persisted path in tests. Only its configuration is covered today — `initialize` is
  one-shot per process, so no test reaches the disk queue end to end.
- [ ] Confirm the added latency is acceptable for the demo. Buffering makes records readable after
  ~4.75 s and exports on an adaptive 1–20 s cycle, which changes what a live demo looks like.
- [ ] Decide whether to strip `device.id`. Upstream's default resource sends
  `identifierForVendor`, ingest does not drop it from traces, and shipping it obliges an app to
  declare a device identifier in App Privacy.
- [ ] Decide whether the package should own screen-view and lifecycle instrumentation, or whether
  that work should go upstream first.
- [ ] Document the final public setup, migration, removal and limitations after product validation.

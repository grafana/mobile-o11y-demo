# Grafana OpenTelemetry iOS: decision record

**Status:** experimental local package. Not published, not supported for production use.

The package follows the composition direction: apps keep instrumenting through standard
OpenTelemetry APIs, and a Grafana package adds setup and defaults around the upstream SDK without a
Grafana telemetry API. API, defaults, install order, version pin and limitations live in the
[package README](../ios/grafana-opentelemetry-ios/README.md). This page records why it looks the
way it does and what is still open.

## Placement

- The package lives in `Mobiles/ios/grafana-opentelemetry-ios` and QuickPizza consumes it as a
  local package reference. That gives it a real app and build without an empty repository.
- It sits beside `QuickPizzaIos.xcodeproj`, **not** inside `QuickPizzaIos/`. The app target is a
  file-system-synchronized group over that folder, so sources there would compile twice.
- The demo repo is not its permanent home. Generic Swift SDK and instrumentation work goes upstream
  to [`opentelemetry-swift`](https://github.com/open-telemetry/opentelemetry-swift). Build-time
  symbol upload stays out of the runtime package. Location, identity, release owner and supported
  upstream window need agreement before extraction.
- Proposed name: **Grafana OpenTelemetry iOS**, entry point `GrafanaOtel.initialize(...)`. The local
  directory name is not a package identity.

## Why it exists

`opentelemetry-swift` has no assembled RUM agent, no autoconfigure module and no facade. Apps wire
providers, exporters, session processors and instrumentations themselves, and several ordering
mistakes fail silently. The package owns that assembly once. This is a platform finding, not an
implementation detail.

## Ownership split

The package owns startup assembly and Grafana defaults (full list in the package README). The app
still owns the runtime config UI, the debug-only console span exporter, business instrumentation,
screen-view events, its instrumentation scope, and opting into automatic redirect protection.

## Decisions

- **Instrumentation extension.** Swift has no `ServiceLoader` and upstream has no discovery, so a
  Grafana instrumentation is either a processor passed through experimental options or code the
  package installs. `URLSessionInstrumentation` swizzles globally with no idempotency guard or
  uninstall, so the package installs it once and exposes `customizeURLSession` instead of letting
  the app build a second one.
- **Trace propagation is a host list, not a policy type.** An earlier enum had an `allHosts` case
  and suffix matching. It duplicated `customizeURLSession`, offered the upstream default the package
  exists to correct, and decided trust by string shape. `firstPartyHosts` is required, exact-match,
  and has no default. Subdomains must be listed; propagating everywhere is unsupported. Both intended.
- **Redirect protection is opt-in and patches upstream's delegates.** Upstream has no redirect hook.
  Two alternatives were rejected: no `resume` fires for a redirect (Foundation follows `3xx` inside
  the task), and a second `resume` swizzle stacks on upstream's most intricate swizzle and writes
  `task.delegate` on app tasks. Shipped: add the redirect callback to upstream's internal
  `AsyncTaskDelegate` / `FakeDelegate`, which covers exactly the delegate-less tasks. Off by default
  because it reaches into internal classes; a test fails on a rename. Wiring `redirectGuard` through
  QuickPizza's `APIClient` was rejected because it puts a package concern in the app's HTTP client.
- **No service-name setting.** The correct value for Faro ingest is "unset", so the setting is
  gone. The package removes the bundle-derived `service.name`; `resourceAttributes` is the escape
  hatch and wins for identity. The package owns only `service.version` and
  `deployment.environment.name`.
- **HTTP semantic convention is fixed at stable.** Ingest reads stable first and falls back, so a
  setting could only choose the deprecated set. The URL sanitiser writes only `url.full`.
- **No install-without-exporting mode.** `otlpEndpoint` is required. A `nil` mode produced a stack
  that looked installed and emitted nothing. The cost: a bad endpoint means no SDK, so QuickPizza
  reports the reason and runs on no-op providers, without its debug console exporter.
- **Disk buffering is on by default.** Application Support plus backup exclusion (caches can be
  evicted; backups would keep full payloads). Caller directories are left alone. Batches drop to
  128 records under the 256 KiB persistence cap. `requeueOnFailure: false` for both signals so the
  disk queue is the only retry. The runtime drains the persistence exporters itself on flush and
  gates them through an owned `exportCondition` on shutdown. Cost: about 4.75 s plus a 1–20 s
  export cycle; `.disabled` stays available.

## Alignment with the iOS field guide

The Frontend Observability field guide *OpenTelemetry Swift (iOS) with Frontend Observability* is
the normative description of this ingest path (maintained outside this repo). Reviewing against it
changed six defaults:

| Guide requirement | What the package does |
| --- | --- |
| `createdRequest` must rewrite the recorded URL; upstream records `absoluteString` | Always rewrites it without query, fragment, user and password, after any caller callback |
| Restrict `shouldInjectTracingHeaders` to hosts you control (defaults to true) | `firstPartyHosts` has **no default** |
| `semanticConvention: .stable` | Fixed at stable |
| `deployment.environment.name` | Uses it, not `deployment.environment` |
| Remove `service.name` so ingest uses the registered app | Always removed; `resourceAttributes` is the escape hatch |
| `requeueOnFailure: false` for traces under persistence, `true` for logs | `false` for both. The log exporter returns `.failure` on a failed upload, so `true` sends it twice. The guide needs the same change |

The other load-bearing guide requirements were already met.

## Differences from the product's setup instructions

The Frontend Observability app page generates native iOS setup code. The package agrees on every
substantive point except three deliberate differences:

- **Dependency pin.** The package tracks a specific upstream revision (see package README), not the
  version the app page names.
- **Trace-context propagation.** The app page leaves `shouldInjectTracingHeaders` at its default
  (inject everywhere). The package requires an explicit `firstPartyHosts`.
- **`PersistenceExporter`.** Not in the app page's product list. The package uses it to offer disk
  buffering, on by default.

## Add and remove

QuickPizza adds the local package and replaces `OTelService`'s hand-written provider, exporter,
session and instrumentation setup with `GrafanaOtel.initialize`. `Tracer.swift`, `Logger.swift` and
`AppEvents.swift` still use `OpenTelemetryApi` types and are unchanged.

To remove the package:

1. Remove the `GrafanaOpenTelemetryIOS` product from the app target and the
   `XCLocalSwiftPackageReference` from the project.
2. Replace `GrafanaOtel.initialize` with direct upstream setup: build and register a
   `TracerProviderSdk` and `LoggerProviderSdk`, and construct the exporters and instrumentations.
3. Keep the upstream products the app links, and add any the package provided transitively.
4. Delete `Mobiles/ios/grafana-opentelemetry-ios`.
5. Leave application tracer, logger, event and propagation calls unchanged.

## Validation

Validated on simulators against local receivers and a local Faro collector (September–October
2026): Debug and Release export of both signals, the resource and session attributes on the wire,
client-side `traceparent` matching the exported spans, buffered replay of traces and logs across a
kill and relaunch without duplicates, and the backup exclusion on the queue directory. Hosted ingest
was not validated. Current evidence and reproduction: [session validation](../ios/session-validation/README.md).

Done: the package builds and is consumed by the demo; config validation, mapping, propagation,
redirect, persistence and initialization have unit coverage; app instrumentation compiles unchanged.

Open:

- [ ] Run against the hosted Faro collector and verify the Mobile O11y signals and Frontend
  Observability product paths.
- [ ] Verify a mobile HTTP span stays connected to the QuickPizza backend trace in Tempo.
- [ ] Automate the add/remove build with a non-Grafana provider.
- [ ] Agree the production repository, package identity, release owner and support window.
- [ ] Validate a released package from a separate consumer resolving it by URL and tag.
- [ ] Decide whether Objective-C interop is required, or state Swift-only is intentional.
- [ ] Add public-API stability checking before a versioned release.
- [ ] Add background and termination flush hooks, and an export-health path beyond the diagnostics
  callback. `forceFlush` blocks on synchronous export, so a hook cannot call it on the main thread.
- [ ] Automate retry across process termination and relaunch (runtime-validated only).
- [ ] Confirm the buffering latency is acceptable for live demos.
- [ ] Decide whether to strip `device.id`. Upstream sends `identifierForVendor`, ingest keeps it on
  traces, and shipping it requires an App Privacy device-identifier declaration.
- [ ] Decide whether the package or upstream should own screen-view and lifecycle instrumentation.
- [ ] Document the final public setup, migration, removal and limitations after product validation.

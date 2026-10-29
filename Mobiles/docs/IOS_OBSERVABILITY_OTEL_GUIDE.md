# iOS OpenTelemetry Instrumentation Guide (QuickPizza)

What the QuickPizza iOS app emits, how it is wired, and how to reuse the approach in your own app.
To run the app and connect it to Grafana Cloud, see the [iOS README](../ios/README.md). For all
four apps side by side, see [MOBILE_OBSERVABILITY_OVERVIEW.md](./MOBILE_OBSERVABILITY_OVERVIEW.md).

## 1. Architecture

Telemetry starts once at launch:

- `Bootstrap.initialize()` resolves and starts `OTelService`.
- `OTelService` calls `GrafanaOtel.initialize(...)` from the local
  [`grafana-opentelemetry-ios`](../ios/grafana-opentelemetry-ios/README.md) package, which registers
  the global providers and installs the instrumentations.
- Features use the injected `Tracing` and `Logging` abstractions, built on standard OTel APIs.

Key files, under `Mobiles/ios/QuickPizzaIos/`:

- `Bootstrap.swift`
- `Core/O11y/OTelService.swift`, `Tracer.swift`, `Logger.swift`, `AppEvents.swift`
- `Core/O11y/Config/OTelConfig.swift` (resolved OTel settings)
- `Core/O11y/Exporters/OSLogSpanExporter.swift` (debug-only span echo to OSLog)
- `Core/Config/ConfigService.swift` (build-time values), `RuntimeConfig.swift` (Debug overrides)

## 2. Signals

| Signal | What is emitted |
| --- | --- |
| **Spans** | Auto: `URLSession` calls, except to the collector host and port. Manual: `auth.login`, `pizza.get_recommendation`, `pizza.rate`. MetricKit: `MXMetricPayload` spans (Apple's daily aggregated CPU, memory, hang and hitch data). |
| **Logs** | Auto: `session.start` / `session.end`; MetricKit `metrickit.diagnostic.{crash,hang,cpu_exception,disk_write_exception}` (plus `app_launch` where the OS supplies it). Manual: app logs at debug/info/warning/error, exceptions (`event_name=exception`), screen views (`event_name=app.screen.view`). |
| **Metrics** | None. No `MeterProvider` is registered, because Faro OTLP ingest does not accept metrics. MetricKit performance data arrives as spans. |

## 3. What is collected

### Resource

Set by `OTelService` from `ConfigService`:

- `service.name=quickpizza-ios`, `service.namespace=quickpizza`
- `service.version` (app version), `service.build` (bundle build number)
- `deployment.environment.name`, hard-coded to `production`

Added by upstream's default resource: `device.id`, `device.model.identifier`, `os.*`,
`telemetry.sdk.language=swift`, `telemetry.sdk.version`.

With Faro ingest, the collector replaces `service.name` with the name registered for the app key
(`QuickPizza_iOS`), also in Tempo and Loki queries.
QuickPizza still sets `service.name` through `resourceAttributes`, because it also supports the
legacy OTLP gateway, where `service.name` and `service.namespace` are the only identity labels.

### Sessions

Package defaults: 15 minutes without a span or log ends a session, 4 hours maximum, and each cold
start begins a new session. Spans and logs carry `session.id`, `session.previous_id` (when
available) and `session.sampling_decision`. These are signal attributes, not resource attributes.

The Faro collector rejects a request with a signal missing `session.id` when session management
is on, so keep the session pipeline. Wiring details: package README,
[Sessions](../ios/grafana-opentelemetry-ios/README.md#sessions).

### Manual spans

`auth.login`, `pizza.get_recommendation` and `pizza.rate` use the internal span kind and record
domain attributes (`pizza.id`, `pizza.name`, `pizza.stars`, `auth.result`). They carry no HTTP
status. Query `http.response.status_code` on their automatic HTTP child spans.

### Automatic HTTP spans

Stable semantic conventions: `http.request.method`, `http.response.status_code`, `url.full`,
`server.*`. Older traces may still have legacy `http.method`, `http.status_code` and `http.url`.
Recorded URLs have query strings, fragments and credentials removed.

The collector host and port are excluded, so the exporter does not trace itself. `traceparent` goes
only to the backend host, derived from `BASE_URL`. The app enables `automaticRedirectProtection`,
so a redirect off the backend host loses the trace context.

### Logs and exceptions

The logger writes to both OSLog (Xcode console) and OTel.

- `logger.error(...)` adds `error.type` and `error.message` when an `Error` is passed.
- `logger.exception(...)` emits `event_name=exception` with `exception.type`,
  `exception.message`, `exception.stacktrace` (current thread) and `error.type`.

Screen views are app-owned: `.trackScreenView()` in `AppEvents.swift` emits `app.screen.view`.
Nothing upstream does this.

### MetricKit

QuickPizza keeps the package's default MetricKit instrumentation on. Crash logs carry
`exception.type`, `exception.message` and `exception.stacktrace`; hang logs carry
`exception.stacktrace` and the hang duration.

Delivery model:

- Performance metrics cover a daily window.
- Diagnostics are delivered separately. [Apple documents immediate diagnostic delivery on iOS 15 and
  later](https://developer.apple.com/documentation/metrickit), but a deliberate crash does not
  guarantee an immediate report. Relaunch the app so it can receive payloads, and allow for the
  export queue.

## 4. Export behavior

- The package appends `/v1/traces` and `/v1/logs` to `OTLP_ENDPOINT`. Only traces and logs are sent.
- Disk buffering is on. Allow tens of seconds for normal export. Batches retry from disk and
  survive relaunch. See [disk buffering](../ios/grafana-opentelemetry-ios/README.md#disk-buffering).
- If `OTLP_ENDPOINT` is empty or invalid, **OpenTelemetry is not started at all**:
  - `OTelService` logs `OTel not initialized: <reason>`, and startup logs it again as a warning.
  - App logs still reach OSLog.
  - Nothing on the OTel side runs: no spans, logs, session events or MetricKit exports, and no
    debug-only `OSLogSpanExporter` output. That exporter is app code: `OTelService` wraps it in a
    `SimpleSpanProcessor` under `#if DEBUG` and passes it via `additionalSpanProcessors`.
- Export failures (404, 401, timeouts) are logged as `OTel SDK: <message>`. The app and the e2e run
  otherwise look the same whether or not data arrives.

Endpoint setup and credentials: [iOS README](../ios/README.md#send-telemetry-to-grafana-cloud).

## 5. Demo workflow

The iOS Debug tab matches the other apps (shared description in
[MOBILE_OBSERVABILITY_OVERVIEW.md](./MOBILE_OBSERVABILITY_OVERVIEW.md)). iOS specifics:

- **Config:** overrides for backend URL, OTLP endpoint, instance ID and API key. Saved to
  `UserDefaults`, applied on next launch via `RuntimeConfigHolder`.
- **Error simulation:** backend headers (`x-error-record-recommendation`,
  `x-delay-record-recommendation`, `x-error-get-ingredients`, `x-delay-get-ingredients`) and client
  faults (`useV2PizzaSchema`, `skipAuthDepInTools`).
- **Quick signals:** debug log, error log, custom event (`event_name=debug.test_event`).
- **Handled exception:** `logger.exception(...)`.
- **Crash:** `fatalError` and force-unwrap-nil variants. Receipt depends on MetricKit; the app has
  no immediate crash-upload handler.

Code: `Features/Debug/Presentation/DebugView.swift`, `DebugViewModel.swift`.

What to expect:

1. With Faro OTLP ingest, look in Frontend Observability; allow tens of seconds for buffered
   events. With the legacy gateway, query Loki with `service_name="quickpizza-ios"`.
2. After a crash, relaunch and check for MetricKit diagnostics. A crash button or a successful
   export attempt does not prove a report arrived.

## 6. Applying this in your own app

Use the package rather than wiring upstream pieces yourself. It is unpublished, so add it as a local
Swift package (Xcode: **File → Add Package Dependencies… → Add Local…**, pick
`Mobiles/ios/grafana-opentelemetry-ios`) and link the `GrafanaOpenTelemetryIOS` product. To import
`OpenTelemetryApi` / `OpenTelemetrySdk` yourself, also add `opentelemetry-swift` at the package's
pinned revision, as QuickPizza does. The
[package README](../ios/grafana-opentelemetry-ios/README.md#usage) has the initialization sample,
requirements and rules.

QuickPizza-specific lessons:

- Register the app in Frontend Observability and use
  `https://faro-collector-<region>.grafana.net/otlp/<appKey>` with no `Authorization` header.
- Faro ingest names the app from the registered app key; `service.name` is needed only for the
  OTLP gateway.
- Skip `initialize` when there is no endpoint. There is no installed-but-not-exporting mode.
- Derive `firstPartyHosts` from your backend URL so they cannot drift apart (see `OTelService`).
- Add a logging facade whose `error` and `exception` map to `error.*` / `exception.*`
  (see `Core/O11y/Logger.swift`).
- Emit screen views yourself.
- Add a non-production debug screen for handled exceptions and intentional crashes.
- Validate end to end: check the data in Frontend Observability and watch `diagnosticsHandler` for
  4xx responses. Check MetricKit diagnostics separately from daily metrics.

## 7. Known limitations

- MetricKit controls diagnostic delivery; the daily metric window does not.
- Delayed MetricKit diagnostics get the session active when they are delivered, not the session
  that crashed, so `session.previous_id` is not a reliable crash-to-session link. The
  [session validation probe](../ios/session-validation/README.md#metrickit-boundary) disables
  MetricKit for that reason; QuickPizza leaves it on.
- `logger.exception` and MetricKit crash logs are both logs from different sources: an
  app-reported exception now versus an OS-reported diagnostic later. There is no dedup.
- No custom OTel metrics.
- The pinned instrumentation has open upstream gaps for
  [HTTP error metadata](https://github.com/open-telemetry/opentelemetry-swift/issues/1203) and
  [implicit server ports](https://github.com/open-telemetry/opentelemetry-swift/issues/1204).
- Package-level limitations (no background flush, no `Retry-After` handling, signal-based session inactivity):
  [package README](../ios/grafana-opentelemetry-ios/README.md#known-limitations).

---

Presenter talking point: "We combine app traces and logs with OS-level diagnostics and daily
performance reports from MetricKit, all through standard OTLP signals."

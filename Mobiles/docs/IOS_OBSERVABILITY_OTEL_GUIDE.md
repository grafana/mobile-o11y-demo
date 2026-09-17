# iOS OpenTelemetry Instrumentation Guide (QuickPizza)

This guide explains how the QuickPizza iOS app is instrumented today with OpenTelemetry Swift, what data it emits, and how to apply the same approach in your own app.

Audience:
- Demo teams who need to explain the telemetry model to customers
- iOS engineers who want to copy this setup

> For a cross-platform comparison covering the Flutter, React Native, and Android demo apps as well, see [`MOBILE_OBSERVABILITY_OVERVIEW.md`](./MOBILE_OBSERVABILITY_OVERVIEW.md).

## 1. High-level architecture

Telemetry is initialized once at app startup:

- `Bootstrap.initialize()` resolves and initializes `OTelService`
- `OTelService` calls `GrafanaOtel.initialize(...)` from the local
  [Grafana OpenTelemetry iOS](./GRAFANA_OPENTELEMETRY_IOS.md) package, which registers the
  global OTel providers and installs the instrumentations
- Feature repositories use injected `Tracing` and `Logging` abstractions

Key files:
- `Mobiles/ios/QuickPizzaIos/Bootstrap.swift`
- `Mobiles/ios/QuickPizzaIos/Core/O11y/OTelService.swift`
- `Mobiles/ios/grafana-opentelemetry-ios/Sources/GrafanaOpenTelemetryIOS/GrafanaOtel.swift`
- `Mobiles/ios/QuickPizzaIos/Core/O11y/Tracer.swift`
- `Mobiles/ios/QuickPizzaIos/Core/O11y/Logger.swift`

## 2. Which telemetry signals are emitted

QuickPizza iOS emits:

1. Traces
- Manual spans around key business operations (login, recommendation, rating)
- Auto HTTP client spans via `URLSessionInstrumentation`
- MetricKit payload spans (pre-aggregated Apple performance data)

2. Logs
- Application logs (`debug`, `info`, `warning`, `error`)
- Exception logs via custom `logger.exception(...)`
- Session lifecycle logs (`session.start`, `session.end`) from Sessions instrumentation
- MetricKit diagnostics logs (including crashes/hangs)

3. Metrics
- No custom OTel Metrics API instrumentation yet
- MetricKit performance data is represented as spans (SDK design)

## 3. What data is collected

### 3.1 Resource attributes (all telemetry)

Passed to the reference kit by `OTelService`, which builds them from `ConfigService`:
- `service.name` (default `quickpizza-ios`)
- `service.namespace` (`quickpizza`)
- `service.version` (app version)
- `service.build` (bundle build number)
- `deployment.environment.name` (`production`)

### 3.2 Sessions

Configured through `GrafanaOtelConfiguration` and applied by the reference kit:
- Session timeout: 15 minutes without a span or log
- Maximum lifetime: 4 hours; each cold start creates a new session
- Span enrichment: `SessionSpanProcessor()`
- Log enrichment: `SessionLogRecordProcessor(...)`
- Session events: `SessionEventInstrumentation.install()`

Attributes added by session processors include:
- `session.id`
- `session.previous_id` (when available)

### 3.3 Manual traces

Examples:
- `auth.login` span
- `pizza.get_recommendation` span
- `pizza.rate` span

These spans use the internal span kind and record domain attributes such as
`pizza.id`, `pizza.name`, `pizza.stars`, and `auth.result`. They do not record HTTP
status. Query `http.response.status_code` on their automatic HTTP child spans.

### 3.4 Auto HTTP spans

`URLSessionInstrumentation` is enabled globally with stable HTTP attributes:
`http.request.method`, `http.response.status_code`, and `url.full`. Recorded URLs
exclude query strings, fragments, and embedded credentials.

The collector host and port are excluded to avoid exporter self-tracing loops.
Trace context is injected only for the configured backend host, and the app enables
`automaticRedirectProtection` to remove it from redirects to other hosts.

### 3.5 Application logs and exception logs

App logger is a composite:
- OSLog (Xcode/device console)
- OpenTelemetry logger provider

`logger.error(...)` emits error logs and sets OTel semantic attributes when an `Error` exists:
- `error.type`
- `error.message`

`logger.exception(...)` emits an exception-style log with:
- `eventName = "exception"`
- `exception.type`
- `exception.message`
- `exception.stacktrace` (current thread call stack)
- `error.type`

### 3.6 Crash and hang diagnostics (MetricKit)

`MetricKitInstrumentation` is registered and retained by the reference kit's runtime handle (required because `MXMetricManager` keeps weak references).

It sends:
- Metric payloads as spans (windowed/aggregated)
- Diagnostic entries as logs:
  - `metrickit.diagnostic.crash`
  - `metrickit.diagnostic.hang`
  - `metrickit.diagnostic.cpu_exception`
  - `metrickit.diagnostic.disk_write_exception`
  - `metrickit.diagnostic.app_launch` (platform/version dependent)

Crash/hang log attributes include OTel exception semantic fields such as:
- `exception.type`
- `exception.message`
- `exception.stacktrace`

Important delivery model:
- Performance metrics cover a daily reporting window.
- Diagnostics have a separate delivery path: [Apple documents immediate diagnostic
  delivery on iOS 15 and later](https://developer.apple.com/documentation/metrickit).
  They are not tied to the daily metric report.
- This integration exports diagnostics when MetricKit supplies them; a deliberate
  crash is not a guarantee of an immediate report in Grafana. Relaunch the app to
  let it receive available payloads, and allow for the OTLP export queue.

## 4. Export model (where telemetry goes)

Configured via `Config.xcconfig` values that are generated into `BuildConfig` at build time.

Inputs:
- `OTLP_ENDPOINT`
- `OTLP_INSTANCE_ID` and `OTLP_API_KEY` (combined into an `Authorization: Basic ...`
  header when both are set; leave both empty for Faro OTLP ingest)

Behavior:
- If `OTLP_ENDPOINT` is set: the reference kit appends the signal paths, so traces go to
  `/v1/traces` and logs to `/v1/logs` beneath the configured base URL (OTLP HTTP)
- Disk buffering is enabled by default. Allow tens of seconds for normal export;
  trace batches survive relaunch, but logs have durable storage only until their
  first export attempt. See the [package buffering limitations](../ios/grafana-opentelemetry-ios/README.md#disk-buffering).
- If `OTLP_ENDPOINT` is empty or not a valid URL: **OpenTelemetry is not initialized at all.** The
  reference kit requires a valid endpoint, so there is no "installed but not exporting" state
  - `OTelService` logs the specific reason, and app startup logs it again as a warning
  - app logs still reach the Xcode console through `ConsoleLogger`, because the app's logger fans
    out to OSLog as well as OTel
  - everything on the OTel side produces nothing: no spans, no log records, no session events, no
    MetricKit diagnostics, and no debug `OSLogSpanExporter` output — that exporter reaches the SDK
    through the kit, so it goes with it

Related files:
- `Mobiles/ios/Config.xcconfig.example`
- `Mobiles/ios/Scripts/generate-config.sh`
- `Mobiles/ios/QuickPizzaIos/Core/Config/ConfigService.swift`

## 5. Demo workflow (customer-facing)

The Debug tab is feature-aligned with the other QuickPizza mobile apps and exposes:

- **Config** — runtime overrides for backend URL, OTLP endpoint, OTLP instance ID, OTLP API key. Persisted in `UserDefaults` and applied on next launch via `RuntimeConfigHolder`.
- **Error simulation** — backend header toggles (`x-error-record-recommendation`, `x-delay-record-recommendation`, `x-error-get-ingredients`, `x-delay-get-ingredients`) and client-side faults (`useV2PizzaSchema`, `skipAuthDepInTools`).
- **Quick Signals** — `Send Debug Log`, `Send Error Log`, `Send Custom Event` (emits `event_name=debug.test_event`).
- **Handled Exception** — calls `logger.exception(...)`, which emits a log record with `event_name=exception` and OTel `exception.{type, message, stacktrace}` semantic attributes.
- **Crash Reporting** — `Crash (fatalError)` and `Crash (force-unwrap nil)` variants. Both terminate the app to exercise MetricKit. Receipt of a diagnostic depends on MetricKit; the app does not install an immediate crash-upload handler.

Files:
- `Mobiles/ios/QuickPizzaIos/Features/Debug/Presentation/DebugView.swift`
- `Mobiles/ios/QuickPizzaIos/Features/Debug/Presentation/DebugViewModel.swift`

Expected outcome on the demo stack:
1. With Faro OTLP ingest, inspect the configured app in Frontend Observability. Allow tens of seconds for buffered logs, custom events, and handled exceptions to export. With the legacy OTLP gateway, inspect Loki using `service_name="quickpizza-ios"`.
2. After a manual crash, relaunch and check for MetricKit diagnostics. Daily performance metrics and diagnostic delivery follow different schedules; neither a crash button nor a successful export attempt proves a report arrived.

## 6. How to apply this in your own iOS app

Use this checklist:

1. Add OpenTelemetry Swift packages
- Core SDK + OTLP HTTP exporters
- `URLSessionInstrumentation`
- `Sessions`
- `MetricKitInstrumentation`

2. Initialize once at app startup
- Register tracer and logger providers
- Set resource attributes (`service.*`, environment)

3. Enable session processors
- `SessionSpanProcessor`
- `SessionLogRecordProcessor`
- `SessionEventInstrumentation.install()`

4. Enable URLSession auto tracing
- Use stable HTTP attributes and sanitize recorded URLs
- Exclude your collector host and port
- Restrict trace-context injection to your backend hosts and protect redirects

5. Add structured app logging facade
- Include `error` and optional `exception` API
- Map to OTel semantic attributes (`error.*`, `exception.*`)

6. Register MetricKit instrumentation
- Keep a strong reference to instrumentation instance

7. Add test hooks
- Non-prod debug screen/action for exception + intentional crash

8. Validate end-to-end
- Verify traces and logs in backend
- Verify MetricKit diagnostic receipt separately from daily performance metrics

## 7. Known limitations and nuances

- MetricKit controls diagnostic availability; daily metric windows do not define diagnostic delivery timing.
- `session.previous_id` is not a guaranteed 1:1 crash-to-session mapping in all delayed-delivery scenarios.
- `logger.exception(...)` and MetricKit crash logs are both logs, but represent different sources:
  - `logger.exception`: app-triggered exception event now
  - MetricKit crash log: OS-reported diagnostic event later

## 8. Current QuickPizza iOS instrumentation inventory

Implemented now:
- OTel traces (manual + URLSession auto)
- OTel logs (app logs + exception logs)
- Session enrichment on spans/logs
- MetricKit crash/hang/diagnostic ingestion
- Debug tab for exception and crash testing

Not yet implemented:
- Custom OTel Metrics API instrumentation
- Crash dedup strategy in app code
- Explicit crash-to-session linkage strategy beyond default session attributes

---

If you are presenting this to customers, the main talking point is:
"We combine app traces and logs with OS-level diagnostics and daily performance reports from MetricKit, all through standard OTLP signals."

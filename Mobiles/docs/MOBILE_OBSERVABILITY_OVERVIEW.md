# Mobile Observability Overview

This document explains what each QuickPizza mobile demo app does, how it is
instrumented, what telemetry it emits, and where that telemetry lands in
Grafana Cloud.

It is intended for two audiences:

- **Demo presenters / SEs** — start with [§ At a glance](#at-a-glance) and
  [§ Where the data lives](#where-the-data-lives).
- **Engineers onboarding to the demo** — read on through
  [§ Per-platform telemetry inventory](#per-platform-telemetry-inventory) and
  [§ iOS vs Android native: what differs](#ios-vs-android-native-what-differs).

> **Demo stack:** an internal Grafana Cloud stack used by the QuickPizza demo
> team. The telemetry examples include a historical `gcx` inventory, with
> Android last observed around 2026-04-24. App configuration and instrumentation
> are checked against this repository; this is not a fresh cloud verification. The
> stack-specific URLs and slugs in this doc are placeholders; substitute your
> own when running these apps yourself. See
> [§ How this was verified](#how-this-was-verified) for the exact queries.

---

## Table of contents

- [At a glance](#at-a-glance)
- [What every QuickPizza mobile app does](#what-every-quickpizza-mobile-app-does)
- [Where the data lives](#where-the-data-lives)
- [Per-platform telemetry inventory](#per-platform-telemetry-inventory)
  - [Flutter (Faro)](#flutter-faro)
  - [React Native (Faro)](#react-native-faro)
  - [iOS native (OpenTelemetry Swift)](#ios-native-opentelemetry-swift)
  - [Android native (OpenTelemetry Android)](#android-native-opentelemetry-android)
- [iOS vs Android native: what differs](#ios-vs-android-native-what-differs)
- [Faro vs OpenTelemetry: side-by-side](#faro-vs-opentelemetry-side-by-side)
- [The shared Debug screen](#the-shared-debug-screen)
- [Known issues / open questions](#known-issues--open-questions)
- [How this was verified](#how-this-was-verified)

---

## At a glance

| Platform | App location | SDK | Service / app name in telemetry |
| --- | --- | --- | --- |
| Flutter (Android + iOS) | `Mobiles/flutter/` | `faro` Dart SDK | `QuickPizza_Flutter` (app_id `69`) |
| React Native (Android + iOS) | `Mobiles/react-native/` | `@grafana/faro-react-native` | `QuickPizza_ReactNative` (app_id `123`) |
| iOS native (SwiftUI) | `Mobiles/ios/` | `opentelemetry-swift` | `quickpizza-ios` → `QuickPizza_iOS` (app_id `204`) |
| Android native (Compose) | `Mobiles/android/` | `opentelemetry-android` (RUM agent) | `quickpizza-android` → `QuickPizza_Android` (app_id `182`) |

All four reach Grafana Cloud Frontend Observability through the Faro collector —
the Faro apps post to `/collect/<appKey>`, the native apps post OTLP/HTTP to
`/otlp/<appKey>` on development collectors. See [§ Where the data lives](#where-the-data-lives) for the
datasources and the legacy OTLP gateway alternative.

The native apps explicitly set `service.name` to `quickpizza-ios` /
`quickpizza-android`. The registered Faro app names identify them in the
Frontend Observability plugin; those names are distinct from the OTel service
names used in the trace queries below.

All four apps talk to the same QuickPizza backend (`/api/pizza`,
`/api/ratings`, `/api/users/token/login`, …) and implement the same core
flows: get a pizza recommendation, rate it, log in, view your profile, and a
shared in-app **Debug** tab for triggering errors/crashes (see
[§ The shared Debug screen](#the-shared-debug-screen)).

---

## What every QuickPizza mobile app does

The user-facing feature set is **the same across all four apps** by design,
so that the four implementations can be compared apples-to-apples for
observability demos. Required screens and workflows are documented in
[`Mobiles/FEATURES.md`](../FEATURES.md).

Common feature set:

- **Home** — get a pizza recommendation; customize calories/toppings/tools.
- **Login** — token auth (`default` / `12345678`).
- **Profile** — list/clear ratings, sign out.
- **About** — app metadata, SDK references.
- **Debug** — shared cross-platform screen for runtime config overrides,
  backend error/latency injection, client-side fault simulation, and
  triggering test logs/exceptions/native crashes.

---

## Where the data lives

All four apps open in the Frontend Observability plugin at
`/a/grafana-kowalski-app/apps/<faro-app-id>` on your Grafana Cloud stack.

Underlying datasources on whichever Grafana Cloud stack you target:

- Faro signals → the stack's Loki datasource (`grafanacloud-<stack>-logs`).
  Faro stores all four signal kinds (`event`, `log`, `measurement`,
  `exception`) as Loki streams with `app_id` / `app_key` / `kind` labels.
- Native OTel signals land in the same datasources. The collector translates
  OTLP to Faro on ingest, so the Loki streams carry the same `app_id` /
  `app_key` / `kind` labels as the Faro apps, under the registered app name
  (`QuickPizza_Android` in the historical inventory). Spans still reach the
  stack's Tempo datasource (`grafanacloud-<stack>-traces`).

The Frontend Observability plugin queries Loki for Faro-shaped data, matched by
those app labels.

The Grafana Cloud OTLP gateway is a legacy alternative for the native apps
([Connect to Grafana Cloud](./CONNECT_GRAFANA_CLOUD.md#alternative-the-otlp-gateway)).
It bypasses the collector, so the data stays raw OTel: streams carry
`service_name` / `service_namespace` only, keep the kebab-case `service.name`,
and gain no app identity. The plugin cannot read them. The
[Mobile OTel RUM dashboard](./MOBILE_OTEL_RUM_DASHBOARD.md) exists for that path.

---

## Per-platform telemetry inventory

The tables combine the historical cloud inventory with the current app
instrumentation, grouped by signal kind. They describe expected signal shapes,
not a guarantee of delivery to a running stack. Anything labeled
**(auto)** comes from the SDK or an SDK-bundled instrumentation; **(manual)**
is code we wrote in `core/o11y/` or in the feature repositories.

### Flutter (Faro)

- **SDK:** `faro` Dart package; version pinned in [pubspec.yaml](../flutter/pubspec.yaml)
- **Init:** `Mobiles/flutter/lib/bootstrap.dart` →
  `core/o11y/faro/faro_init.dart` → `Faro` from `package:faro`
- **Faro app:** registry name `QuickPizza_Flutter`, id `69`. The SDK is
  configured in `Mobiles/flutter/lib/core/o11y/faro/faro_init.dart` to send
  `app_name=QuickPizza_Flutter`, matching the React Native app
  (`QuickPizza_ReactNative`).
- **View names:** go_router paths such as `/`, `/about`, `/debug`, and
  `/debug/config`. The root and shell navigators each register Faro's
  navigation observer so bottom navigation tabs and full-screen routes use the
  same path-based naming convention.

| Signal kind | Examples | Source |
| --- | --- | --- |
| `event` | `faro.tracing.fetch` (HTTP auto), `user_interaction`, `view_changed`, `app_lifecycle_changed`, `session_start`, `faro.user.action`, `pizza_requested`, `pizza_received`, `pizza_rated`, `login_screen_opened`, `user_logged_out` | mostly auto; `pizza_*` and `login_*` are manual via `core/o11y/events/o11y_events.dart` |
| `log` | severity `debug` / `warn` / `error` | manual via `core/o11y/loggers/o11y_logger.dart` (`MultiO11yLogger` → `ConsoleO11yLogger` + `FaroO11yLogger`) |
| `exception` | type `API`, `UI`, `flutter_error` | manual via `core/o11y/errors/o11y_errors.dart` + Faro's global Flutter error handler installed by `faro.runApp` |
| `measurement` | `app_memory`, `app_cpu_usage`, `app_refresh_rate`, `app_frames_rate`, `app_frozen_frame`, `app_startup` | auto, from Faro mobile metrics instrumentation |

Resource attributes on every signal: `app_name`, `app_version`,
`app_environment=production`, `sdk_name`, `sdk_version`, `user_id`,
`user_username`, `session_id`, plus a rich `session_attr_*` block (Dart
version, device brand/manufacturer/model/id, `device_is_physical`, OS,
detailed OS string).

The Debug screen triggers native crashes through a custom `MethodChannel`-based
`NativeCrashService` (see `Mobiles/flutter/lib/features/debug/domain/`). Faro
handles crash capture and reporting on the next launch.

Flutter also creates manual business spans through
[`o11y_traces.dart`](../flutter/lib/core/o11y/traces/o11y_traces.dart). Faro sends
these to tracing; the companion DemoRum implementation only logs to the console.

### React Native (Faro)

- **SDK:** `@grafana/faro-react-native` and `@grafana/faro-react-native-tracing`; versions pinned in [package.json](../react-native/package.json)
- **Init:** `Mobiles/react-native/src/bootstrap.ts` →
  `core/o11y/faroSdk.ts`
- **Faro app:** registry name `QuickPizza_ReactNative`, id `123`

| Signal kind | Examples | Source |
| --- | --- | --- |
| `event` | `faro.tracing.fetch` + `faro.tracing.xml-http-request` (HTTP auto via dual fetch+XHR interception), `view_changed`, `faro.user.action`, `app_lifecycle_changed`, `session_start`, `faro_initialized`, `pizza_requested` / `pizza_received` / `pizza_rated`, `login_screen_opened`, `user_logged_out`, `debug_custom_event` | mostly auto; pizza/login/debug events are manual via `src/core/o11y/o11yEvents.ts` |
| `log` | severity `debug` / `info` / `warn` / `error` | manual via `src/core/o11y/o11yLogs.ts` |
| `exception` | type `crash` (native, e.g. `CRASH_NATIVE: Application crash (Native), status: 11`), `Error`, `PizzaRecommendationError`, `HandledDebugException` | crash auto via Faro CrashKit; others manual via `src/core/o11y/o11yErrors.ts` |
| `measurement` | `app_memory`, `app_cpu_usage`, `app_frames_rate`, `app_frozen_frame`, `app_startup`, plus app-specific `pizza.recommendation`, `pizza.rating` | auto, plus custom via `src/core/o11y/o11yMetrics.ts` |

Resource attributes are similar to Flutter but **richer**: includes
`device_battery_level`, `device_is_charging`, `device_carrier`,
`device_memory_total`, `device_memory_used`, `device_type`, and
`react_native_version`. RN sets `app_environment=development` in debug builds
and `production` in release builds. Flutter's entry point sets `production`.

Custom `pizza.recommendation` / `pizza.rating` measurements are unique to
the RN app — Flutter doesn't currently emit business measurements.

### iOS native (OpenTelemetry Swift)

- **SDK:** `opentelemetry-swift` (`telemetry_sdk_language=swift`,
  `telemetry_sdk_name=opentelemetry`); the tested version is pinned in the Xcode
  project's `Package.resolved`
- **Init:** `Mobiles/ios/QuickPizzaIos/Bootstrap.swift` →
  `Core/O11y/OTelService.swift` → `GrafanaOtel.initialize(...)` from the local
  [Grafana OpenTelemetry iOS](./GRAFANA_OPENTELEMETRY_IOS.md) package, which owns
  SDK startup while app instrumentation stays on standard OTel APIs
- **OTel service.name:** `quickpizza-ios`,
  service.namespace `quickpizza`

| Signal | Examples | Source |
| --- | --- | --- |
| Spans (Tempo) | `HTTP GET` / `HTTP POST` (auto, `URLSessionInstrumentation`, stable HTTP attribute keys), `pizza.get_recommendation` / `auth.login` / `pizza.rate` (manual), `MXMetricPayload` (auto, MetricKit pre-aggregated 24h payloads) | manual via `Core/O11y/Tracer.swift`; HTTP auto via `URLSessionInstrumentation`; MetricKit auto via `MetricKitInstrumentation` |
| Logs (Loki) | severity `INFO` / `DEBUG` / `WARN` / `ERROR`; `event_name=app.screen.view` (manual screen-view tracking), `session.start` / `session.end` (auto from Sessions instrumentation), `event_name=exception` for `logger.exception(...)`, MetricKit `metrickit.diagnostic.*` for crashes/hangs/CPU/disk-write exceptions | manual app logger + auto SDK |
| Metrics | _none yet_ — there is no `MeterProvider` configured. MetricKit performance data is delivered as spans, not metrics. | — |

Resource attributes carry: `service.name`, `service.namespace`,
`service.version`, `service.build`, `deployment.environment.name`, `os.name`,
`os.version`, `os.description`, `device.id`, `device.model.identifier`
(e.g. `iPhone16,1`), and `telemetry.sdk.{language, name, version}`. Session
processors add `session.id` and, when available, `session.previous_id` to
individual spans and log records. The instrumentation scope is separate
metadata, not a resource attribute.

**iOS does not auto-emit** `screen.view`, lifecycle spans (`AppStart` /
`Paused` / `Stopped`), `app.jank`, or `device.crash` events. The iOS app
**does** emit `app.screen.view` events manually via a `.trackScreenView()`
view modifier.

The local iOS package buffers spans and pre-export log batches to disk by
default. Export is asynchronous. Spans have durable retries; log retries after
the first export attempt are in memory only. Refer to the
[package buffering limitations](./GRAFANA_OPENTELEMETRY_IOS.md) for details.

For deeper iOS detail see
[`IOS_OBSERVABILITY_OTEL_GUIDE.md`](./IOS_OBSERVABILITY_OTEL_GUIDE.md).

### Android native (OpenTelemetry Android)

- **SDK:** `opentelemetry-android` (`telemetry_sdk_language=java`) — version pinned in [`Mobiles/android/gradle/libs.versions.toml`](../android/gradle/libs.versions.toml)
- **Init:** `Mobiles/android/app/src/main/java/com/grafana/quickpizza/core/o11y/OTelService.kt`
  → `GrafanaOtel.initialize(...)`, which delegates to
  `OpenTelemetryRumInitializer.initialize(...)`
- **OTel service.name:** `quickpizza-android`, service.namespace `quickpizza`
- **Conventions:** the app sets `useLatestExperimentalSemanticConventions=false`,
  preserving names such as `device.crash` and `screen.name`. These are app
  configuration choices, not the SDK's latest defaults.

| Signal | Examples | Source |
| --- | --- | --- |
| Spans (Tempo) | `GET` (auto, OkHttp telemetry), `AppStart` / `Paused` / `Stopped` (auto, lifecycle instrumentation), `pizza.get_recommendation` / `auth.login` / `pizza.rate` (manual) | manual via `core/o11y/AppTracer.kt`; rest auto from RUM agent |
| Logs (Loki) | `event_name=screen.view` (auto, Activity/Fragment), `event_name=app.screen.view` (manual, Compose routes), `event_name=app.jank` (auto, slow-rendering instrumentation), `session.start` (auto), `rum.sdk.init.{started, span.exporter, net.provider}` (auto SDK self-telemetry), `event_name=exception` (manual `logger.exception`), `event_name=device.crash` (auto, `CrashReporter`; force-flushed at crash time, delivered next launch when disk buffering is on), `event_name=device.anr` (auto ANR detection), `event_name=debug.test_event` (manual from Debug screen) | mostly auto; `app.screen.view`, `exception`, and `debug.*` are manual |
| Metrics | Disabled by the local Grafana package with `disableMetrics()`; jank information is emitted as events. | — |

Resource attributes include `service.*`,
`os.name`, `os.version`, `os.description`, `os.build_id`,
`android.os.api_level`, `device.manufacturer`, `device.model.identifier`,
`device.model.name`, `app.installation.id`, and
`telemetry.sdk.{language, name, version}`. Signal attributes include
`network.connection.type` (e.g. `wifi`), `screen.name` (current Activity), and
`session.id`. The manual Compose `app.screen.view` events add
`app.screen.name`, `nav.previous_destination`, and `nav.kind`; they do not set
`nav.destination`. App instrumentation uses the scope `com.grafana.quickpizza`.

Native C/C++ crashes have a separate demo-owned path:
[`NativeExitCrashReporter`](../android/app/src/main/java/com/grafana/quickpizza/nativecrash/NativeExitCrashReporter.kt)
replays `ApplicationExitInfo` on the next launch on Android 11 or later. This
is distinct from the SDK's uncaught JVM exception reporter.

> **Last verified in cloud:** ~2026-04-24. The inventory combines that
> historical observation with the instrumentation registered in the repository.

---

## iOS vs Android native: what differs

Both export OTel/HTTP to the same Grafana Cloud stack, but the SDKs do
materially different amounts of work for you out of the box.

| Concern | iOS (`opentelemetry-swift`) | Android (`opentelemetry-android`) |
| --- | --- | --- |
| Auto HTTP spans | Yes — `URLSessionInstrumentation` | Yes — OkHttp `Call.Factory` wrapper |
| Auto lifecycle spans | **No** | Yes — `AppStart`, `Paused`, `Stopped` |
| Auto screen view events | **No** (we emit `app.screen.view` manually via a SwiftUI view modifier) | Activity/Fragment events; Compose routes use manual `app.screen.view` |
| Auto crash capture | Via Apple **MetricKit** — OS-managed diagnostic delivery; separate from daily performance reports | Via OTel-Android `CrashReporter` — captured and force-flushed at crash time; delivered on next app launch while disk buffering is on |
| Auto ANR / hang | Via MetricKit diagnostic reports | Yes — `event_name=device.anr` runtime |
| Auto slow-frame / jank | **No** (MetricKit hitch metrics arrive as `MXMetricPayload` spans) | Yes — `event_name=app.jank` |
| Auto session lifecycle | Yes — `Sessions` library (`session.start` / `session.end` log records, `session.id` + `session.previous_id` on every signal) | Yes — emits `session.start`; `session.id` on every signal |
| Network class attribute | _Not exposed_ | Yes — `network.connection.type` (e.g. `wifi`) |
| Compose / SwiftUI nav attrs | Manual events carry `app.screen.name` | Manual events carry `app.screen.name` / `nav.previous_destination` / `nav.kind` |
| Device hardware attrs | `device.id`, `device.model.identifier` | `device.manufacturer`, `device.model.identifier`, `device.model.name`, `android.os.api_level`, `app.installation.id` |
| Performance / Apple-specific | `MXMetricPayload` spans (CPU, memory, hangs, hitch ratios — daily) | `app.jank` events, `rum.sdk.init.*` self-telemetry |
| Custom OTel Metrics API | Not configured | Export explicitly disabled by local package |

The Android demo enables automatic lifecycle, Activity/Fragment screen, jank,
and ANR instrumentation. The iOS demo uses `MetricKitInstrumentation` for
OS-level diagnostics. Both apps add manual screen and business events for
their Compose or SwiftUI interfaces.

---

## Faro vs OpenTelemetry: side-by-side

| | Faro (Flutter, RN) | OpenTelemetry (iOS, Android) |
| --- | --- | --- |
| Wire format | Faro JSON → Faro collector `/collect/<appKey>` | OTLP/HTTP → Faro collector `/otlp/<appKey>`, translated to Faro on ingest |
| Signal model | Four Loki signal kinds: `event`, `log`, `measurement`, `exception`; trace payloads go to Tempo. | Two kinds we use today: spans (Tempo) + log records (Loki). |
| Auto HTTP | Faro fetch/XHR instrumentation emits HTTP events and tracing data; trace/span IDs correlate them | Native HTTP client wrappers emit OTel spans |
| Auto user actions | `event_name=faro.user.action` (Flutter + RN) | _None_ |
| Auto perf metrics | `app_memory`, `app_cpu_usage`, `app_frames_rate`, `app_frozen_frame`, `app_startup` (both) | _None on iOS_; `app.jank` events on Android |
| Crashes | Native crash → `kind=exception, type=crash` (FaroCrashKit) | iOS: MetricKit diagnostics; Android: SDK JVM crash reporting plus demo-owned native crash replay |
| Where to query | Frontend Observability plugin (Loki under the hood) | Same — the collector stamps the app labels the plugin needs |
| Where to view | Frontend Observability plugin (per-app drilldown UI) | Same. On the legacy OTLP gateway path the plugin cannot read the data; use the [Mobile OTel RUM dashboard](./MOBILE_OTEL_RUM_DASHBOARD.md) |
| User context | `user_id` / `user_username` (Faro auto when set via SDK) | Not yet attached on every signal — `user.id` is the current OTel user identifier; tracked in [#48](https://github.com/grafana/mobile-o11y-demo/issues/48) / [`OTEL_MOBILE_MATURITY.md` § M-001](./OTEL_MOBILE_MATURITY.md#m-001--no-first-class-user-context-enduserid-on-mobile-sdks) |

---

## The shared Debug screen

All four apps now have a feature-aligned **Debug** tab that lets demo
presenters trigger telemetry on demand. The screen has the same five
sections everywhere:

1. **Config entry card** — opens a sub-screen for runtime overrides of
   `BASE_URL`, OTLP endpoint / Faro collector URL, and credentials.
   Overrides persist to local storage and apply on next launch (a
   "Restart required" banner shows when the active config differs from
   the saved one).
2. **Error simulation** — toggles that propagate to the QuickPizza
   backend via headers (`x-error-record-recommendation`,
   `x-delay-record-recommendation`, `x-error-get-ingredients`,
   `x-delay-get-ingredients`) plus client-side faults
   (`useV2PizzaSchema`, `skipAuthDepInTools`).
3. **Quick signals** — buttons to send a debug log, an error log, and a
   custom event end-to-end through the SDK.
4. **Handled exception** — throws inside a `try/catch` and reports it via
   the appropriate API (`o11yErrors.reportError` for Faro,
   `logger.exception(...)` for OTel).
5. **Native crash** — terminates the app via a real native crash so we
   can exercise the crash-reporting path.

Per-platform extras:

- **Android only:** an **OTel SDK section** with a `Disable disk
  buffering` toggle (turn off for ~1–6s telemetry latency at the cost
  of offline resilience, vs the default ~30–45s buffered window) and an
  **ANR card** that blocks the main thread for 10 s.
- **iOS only:** the **Crash Reporting** card explicitly notes that
  MetricKit diagnostic delivery is controlled by Apple and is separate from
  daily performance metrics; immediate visibility in Grafana Cloud is not guaranteed.

Code:

- Flutter — `Mobiles/flutter/lib/features/debug/presentation/debug_screen.dart`
- React Native — `Mobiles/react-native/src/features/debug/presentation/DebugScreen.tsx`
- iOS — `Mobiles/ios/QuickPizzaIos/Features/Debug/Presentation/DebugView.swift`
- Android — `Mobiles/android/app/src/main/java/com/grafana/quickpizza/features/debug/DebugScreen.kt`

---

## Known issues / open questions

**SDK-level gaps** (missing capabilities, awkward APIs — candidates for
upstream contribution) are tracked separately in
[`OTEL_MOBILE_MATURITY.md`](./OTEL_MOBILE_MATURITY.md). Currently logged
there:

- `M-001` — No app-wide user context (`user.id`) configured in the mobile OTel
  SDKs (tracked in [#48](https://github.com/grafana/mobile-o11y-demo/issues/48)).
- `M-002` — No OTel metrics export in the native demos.
- `M-003` — Android RUM agent processor extensibility (needs verification).
- `M-004` — Screen / view transitions not captured as spans (iOS has no
  automatic SwiftUI screen tracking configured; Android Compose routes use
  manual `app.screen.view` events).

---

## How this was verified

The original cloud inventory used `gcx` against the demo stack. The
2026-09-17 documentation review checks repository code, dependency manifests,
and dashboard JSON; it does not repeat those cloud queries. To verify your
own deployment, substitute your context, datasource identifiers, and app IDs
in the examples below. The raw OTel log query targets the OTLP gateway path;
for Faro ingest use the app-label queries.

```bash
gcx config use-context "<your-stack-context>"

# Faro app discovery
gcx frontend apps list -o json \
  | tail -n +2 | jq -r '.[] | select(.spec.name | test("QuickPizza"; "i")) | "\(.spec.id)\t\(.spec.name)"'

# Faro signal kinds, last 7 days, for app_id=69 (Flutter) / 123 (RN)
gcx logs query -d grafanacloud-logs \
  'sum by (kind) (count_over_time({app_id="69"}[24h]))' \
  --since 168h --step 24h -o json

# Faro top events
gcx logs query -d grafanacloud-logs \
  'topk(30, sum by (event_name) (count_over_time({app_id="69", kind="event"} | logfmt event_name [24h])))' \
  --since 168h --step 24h -o json

# OTel spans for native apps
gcx traces query -d grafanacloud-traces \
  '{resource.service.name="quickpizza-ios"}' --since 168h --limit 200 -o json
gcx traces query -d grafanacloud-traces \
  '{resource.service.name="quickpizza-android"}' --since 720h --limit 200 -o json

# OTel log event_names (Android RUM agent emits a lot of these)
gcx logs query -d grafanacloud-logs \
  'sum by (event_name) (count_over_time({service_name="quickpizza-android"}[24h]))' \
  --since 720h --step 24h -o json
```

For deeper investigations against any of these apps, the `debug-faro-app`
Claude skill (Faro side) and `gcx skills install debug-with-grafana` (general
OTel side) both apply.

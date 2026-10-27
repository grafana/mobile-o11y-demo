# Mobile Observability Overview

What each QuickPizza mobile app emits and where it lands in Grafana Cloud. The
screens and workflows are the same in all four apps; see
[FEATURES.md](../FEATURES.md). App IDs below come from the internal demo stack;
yours will differ.

## At a glance

| Platform | App location | SDK | Service / app name in telemetry |
| --- | --- | --- | --- |
| Flutter (Android + iOS) | `Mobiles/flutter/` | `faro` Dart SDK | `QuickPizza_Flutter` (app_id `69`) |
| React Native (Android + iOS) | `Mobiles/react-native/` | `@grafana/faro-react-native` | `QuickPizza_ReactNative` (app_id `123`) |
| iOS native (SwiftUI) | `Mobiles/ios/` | `opentelemetry-swift` via the local Grafana package | `quickpizza-ios` → `QuickPizza_iOS` (app_id `204`) |
| Android native (Compose) | `Mobiles/android/` | `opentelemetry-android` RUM agent via the local Grafana package | `quickpizza-android` → `QuickPizza_Android` (app_id `182`) |

The Faro apps post to the Faro collector at `/collect/<appKey>`; the native
apps post OTLP/HTTP to `/otlp/<appKey>` on the same collector. Endpoint setup
is in [Connect to Grafana Cloud](./CONNECT_GRAFANA_CLOUD.md).

The native apps set `service.name` to `quickpizza-ios` / `quickpizza-android`.
The plugin lists them under their registered Faro app names; trace queries use
the OTel service names. The iOS package strips the bundle-derived
`service.name` so ingest can apply the registered identity, and the app sets it
back so the legacy gateway path still has a service name.

## Where the data lives

Each app opens in the Frontend Observability plugin at
`/a/grafana-kowalski-app/apps/<faro-app-id>`. Underneath:

- **Loki** (`grafanacloud-<stack>-logs`): Faro `event`, `log`, `measurement`,
  and `exception` streams with `app_id` / `app_key` / `kind` labels. The
  collector gives translated native OTel logs the same labels under the
  registered app name. The plugin queries Loki by these labels.
- **Tempo** (`grafanacloud-<stack>-traces`): spans from all four apps.

Data sent through the legacy OTLP gateway stays raw OTel without these labels,
so the plugin cannot read it. See
[Connect to Grafana Cloud](./CONNECT_GRAFANA_CLOUD.md#alternative-the-otlp-gateway).

## Per-platform telemetry inventory

**(auto)** means the SDK or a bundled instrumentation emits it; **(manual)** is
app code in `core/o11y/` or the feature repositories. The tables describe the
expected signal shapes, not guaranteed delivery.

### Flutter (Faro)

- **SDK:** `faro` Dart package; version pinned in [pubspec.yaml](../flutter/pubspec.yaml)
- **Init:** `Mobiles/flutter/lib/bootstrap.dart` →
  `core/o11y/faro/faro_init.dart`, which sends `app_name=QuickPizza_Flutter`
  with `enableCrashReporting: true`. The app root is wrapped in
  `FaroAssetTracking` and `FaroUserInteractionWidget`.
- **View names:** go_router paths such as `/`, `/about`, `/debug`, and
  `/debug/config`. The root and shell navigators both register
  `FaroNavigationObserver` (plus `DemoRumNavigatorObserver`), so tabs and
  full-screen routes are named the same way.

| Signal kind | Examples | Source |
| --- | --- | --- |
| `event` | `faro.tracing.fetch` (HTTP auto), `user_interaction`, `view_changed`, `app_lifecycle_changed`, `session_start`, `faro.user.action`, `pizza_requested`, `pizza_received`, `pizza_rated`, `login_screen_opened`, `user_logged_out` | mostly auto; `pizza_*` and `login_*` are manual via `core/o11y/events/o11y_events.dart` |
| `log` | severity `debug` / `warn` / `error` | manual via `core/o11y/loggers/o11y_logger.dart` (`MultiO11yLogger` → `ConsoleO11yLogger` + `FaroO11yLogger`) |
| `exception` | type `API`, `UI`, `flutter_error` | manual via `core/o11y/errors/o11y_errors.dart` + Faro's global Flutter error handler installed by `faro.runApp` |
| `measurement` | `app_memory`, `app_cpu_usage`, `app_refresh_rate`, `app_frames_rate`, `app_frozen_frame`, `app_startup` | auto, from Faro mobile metrics instrumentation |

Every signal carries `app_name`, `app_version`, `app_environment=production`,
`sdk_name`, `sdk_version`, `user_id`, `user_username`, `session_id`, and a
`session_attr_*` block (Dart version, device brand/manufacturer/model/id,
`device_is_physical`, OS).

Manual business spans come from
[`o11y_traces.dart`](../flutter/lib/core/o11y/traces/o11y_traces.dart); Faro
sends them to tracing, and the companion DemoRum stand-in only logs them.
Native crashes are triggered through a `MethodChannel`-based
`NativeCrashService` (`lib/features/debug/domain/`); Faro's crash reporting
sends them on the next launch.

### React Native (Faro)

- **SDK:** `@grafana/faro-react-native` and `@grafana/faro-react-native-tracing`; versions pinned in [package.json](../react-native/package.json)
- **Init:** one `initializeFaro({...})` call in `Mobiles/react-native/src/bootstrap.ts` (`src/core/o11y/faroSdk.ts` only re-exports the Faro APIs). Tracing, crash reporting, ANR tracking and vitals are config flags.

| Signal kind | Examples | Source |
| --- | --- | --- |
| `event` | `faro.tracing.fetch` + `faro.tracing.xml-http-request` (HTTP auto via dual fetch+XHR interception), `view_changed`, `faro.user.action`, `app_lifecycle_changed`, `session_start`, `faro_initialized` (manual, `bootstrap.ts`), `pizza_requested` / `pizza_received` / `pizza_rated`, `login_screen_opened`, `user_logged_out`, `debug_custom_event` | mostly auto; pizza/login/debug events are manual via `src/core/o11y/o11yEvents.ts` |
| `log` | severity `debug` / `info` / `warn` / `error` | manual via `src/core/o11y/o11yLogs.ts` |
| `exception` | type `crash` (native, e.g. `CRASH_NATIVE: Application crash (Native), status: 11`), `Error`, `PizzaRecommendationError`, `HandledDebugException` | crash auto via Faro CrashKit; others manual via `src/core/o11y/o11yErrors.ts` |
| `measurement` | `app_memory`, `app_cpu_usage`, `app_frames_rate`, `app_frozen_frame`, `app_startup`, `anr` (Android only, `anrTracking`), plus app-specific `pizza.recommendation` (`pizza_id`, `calories`, `vegetarian` 0/1) and `pizza.rating` (`pizza_id`, `stars`) | auto, plus custom via `src/core/o11y/o11yMetrics.ts` |

Attributes are like Flutter's plus `device_battery_level`,
`device_is_charging`, `device_carrier`, `device_memory_total`,
`device_memory_used`, `device_type`, and `react_native_version`.
`app_environment` is `development` in debug builds and `production` in release
builds. The custom `pizza.*` measurements are unique to React Native.

### iOS native (OpenTelemetry Swift)

- **SDK:** `opentelemetry-swift`; revision pinned in the package's
  [`Package.swift`](../ios/grafana-opentelemetry-ios/Package.swift) (the app's `Package.resolved` records it)
- **Init:** `Mobiles/ios/QuickPizzaIos/Bootstrap.swift` →
  `Core/O11y/OTelService.swift` → `GrafanaOtel.initialize(...)` from the local
  [Grafana OpenTelemetry iOS](./GRAFANA_OPENTELEMETRY_IOS.md) package, which
  owns SDK startup; app instrumentation uses standard OTel APIs
- **OTel service:** `service.name=quickpizza-ios`, `service.namespace=quickpizza`

| Signal | Examples | Source |
| --- | --- | --- |
| Spans (Tempo) | `HTTP GET` / `HTTP POST` (auto, `URLSessionInstrumentation`, stable HTTP attribute keys), `pizza.get_recommendation` / `auth.login` / `pizza.rate` (manual), `MXMetricPayload` (auto, MetricKit pre-aggregated 24h payloads) | manual via `Core/O11y/Tracer.swift`; HTTP auto via `URLSessionInstrumentation`; MetricKit auto via `MetricKitInstrumentation` |
| Logs (Loki) | severity `INFO` / `DEBUG` / `WARN` / `ERROR`; `event_name=app.screen.view` (manual screen-view tracking), `session.start` / `session.end` (auto from Sessions instrumentation), `event_name=exception` for `logger.exception(...)`, MetricKit `metrickit.diagnostic.*` for crashes/hangs/CPU/disk-write exceptions | manual app logger + auto SDK |
| Metrics | None. No `MeterProvider` is configured; MetricKit performance data arrives as spans. | — |

Resource attributes: `service.name`, `service.namespace`, `service.version`,
`service.build`, `deployment.environment.name`, `os.name`, `os.version`,
`os.description`, `device.id`, `device.model.identifier` (e.g. `iPhone16,1`),
and `telemetry.sdk.{language, name, version}`. The session sampler and log
processor add `session.id` and, when available, `session.previous_id` to each
span and log record.

iOS does **not** auto-emit `screen.view`, lifecycle spans, `app.jank`, or
`device.crash`. The app emits `app.screen.view` manually through a
`.trackScreenView()` view modifier.

The package buffers spans and logs to disk and retries across relaunch; see
[disk buffering](../ios/grafana-opentelemetry-ios/README.md#disk-buffering).
More iOS detail: [IOS_OBSERVABILITY_OTEL_GUIDE.md](./IOS_OBSERVABILITY_OTEL_GUIDE.md).

### Android native (OpenTelemetry Android)

- **SDK:** `opentelemetry-android`; version pinned in [`libs.versions.toml`](../android/gradle/libs.versions.toml)
- **Init:** `Mobiles/android/app/src/main/java/com/grafana/quickpizza/core/o11y/OTelService.kt`
  → `GrafanaOtel.initialize(...)` → `OpenTelemetryRumInitializer.initialize(...)`
- **OTel service:** `service.name=quickpizza-android`, `service.namespace=quickpizza`
- **Conventions:** the app sets `useLatestExperimentalSemanticConventions=false`,
  which keeps names such as `device.crash` and `screen.name`

| Signal | Examples | Source |
| --- | --- | --- |
| Spans (Tempo) | `GET` (auto, OkHttp telemetry), `AppStart` / `Paused` / `Stopped` (auto, lifecycle instrumentation), `pizza.get_recommendation` / `auth.login` / `pizza.rate` (manual) | manual via `core/o11y/AppTracer.kt`; rest auto from RUM agent |
| Logs (Loki) | `event_name=screen.view` (auto, Activity/Fragment), `event_name=app.navigation.complete` (SDK Compose navigation, after explicit setup), `event_name=app.jank` (auto, slow-rendering instrumentation), `session.start` (auto), `rum.sdk.init.{started, span.exporter, net.provider}` (auto SDK self-telemetry), `event_name=exception` (manual `logger.exception`), `event_name=device.crash` (auto, `CrashReporter`; force-flushed at crash time, delivered next launch when disk buffering is on), `event_name=device.anr` (auto ANR detection), `event_name=debug.test_event` (manual from Debug screen) | mostly auto; Compose navigation requires explicit setup; `exception` and `debug.*` are manual |
| Metrics | Disabled by the local Grafana package (`disableMetrics()`); jank is emitted as events. | — |

Resource attributes: `service.*`, `os.name`, `os.version`, `os.description`,
`os.build_id`, `android.os.api_level`, `device.manufacturer`,
`device.model.identifier`, `device.model.name`, `app.installation.id`, and
`telemetry.sdk.{language, name, version}`. Signal attributes include
`network.connection.type` (e.g. `wifi`), `screen.name`, and `session.id`.

`MainActivity` attaches Compose navigation tracking with
`navController.withOpenTelemetry(rum)`, imported from Kotlin package
`io.opentelemetry.instrumentation.compose.navigation`. Its `app.navigation.complete` events
carry `app.navigation.destination.name` (the route pattern) under instrumentation scope
`io.opentelemetry.android.instrumentation.compose.navigation`. App business
instrumentation uses scope `com.grafana.quickpizza`.

Native C/C++ crashes use a separate demo-owned path:
[`NativeExitCrashReporter`](../android/app/src/main/java/com/grafana/quickpizza/nativecrash/NativeExitCrashReporter.kt)
replays `ApplicationExitInfo` on the next launch on Android 11+.

## iOS vs Android native: what differs

| Concern | iOS (`opentelemetry-swift`) | Android (`opentelemetry-android`) |
| --- | --- | --- |
| Auto HTTP spans | Yes — `URLSessionInstrumentation` | Yes — OkHttp, via the `OkHttpTelemetry` `Call.Factory` wrapper plus the Byte Buddy `okhttp3-agent` |
| Auto lifecycle spans | **No** | Yes — `AppStart`, `Paused`, `Stopped` |
| Auto screen view events | **No** (manual `app.screen.view` via a SwiftUI view modifier) | Activity/Fragment `screen.view`; Compose `app.navigation.complete` after explicit setup |
| Auto crash capture | Apple **MetricKit** — OS-managed diagnostic delivery, separate from daily performance reports | OTel-Android `CrashReporter` — force-flushed at crash time, delivered on next launch while disk buffering is on |
| Auto ANR / hang | MetricKit diagnostic reports | Yes — `event_name=device.anr` at runtime |
| Auto slow-frame / jank | **No** (MetricKit hitch metrics arrive as `MXMetricPayload` spans) | Yes — `event_name=app.jank` |
| Auto session lifecycle | Yes — `Sessions` library (`session.start` / `session.end`, `session.id` on spans and logs, `session.previous_id` when available) | Yes — `session.start`; `session.id` on every signal |
| Network class attribute | Not exposed | `network.connection.type` (e.g. `wifi`) |
| Compose / SwiftUI nav attrs | Manual events carry `app.screen.name` | SDK navigation events carry `app.navigation.destination.name` |
| Device hardware attrs | `device.id`, `device.model.identifier` | `device.manufacturer`, `device.model.identifier`, `device.model.name`, `android.os.api_level`, `app.installation.id` |
| Performance | `MXMetricPayload` spans (CPU, memory, hangs, hitch ratios — daily) | `app.jank` events, `rum.sdk.init.*` self-telemetry |
| OTel Metrics API | Not configured | Export disabled by the local package |

## Faro vs OpenTelemetry: side-by-side

| | Faro (Flutter, RN) | OpenTelemetry (iOS, Android) |
| --- | --- | --- |
| Wire format | Faro JSON → Faro collector `/collect/<appKey>` | OTLP/HTTP → Faro collector `/otlp/<appKey>`, translated to Faro on ingest |
| Signal model | Four Loki kinds: `event`, `log`, `measurement`, `exception`; traces go to Tempo | Spans (Tempo) + log records (Loki) |
| Auto HTTP | Faro fetch/XHR instrumentation emits HTTP events and tracing data, correlated by trace/span IDs | Native HTTP client wrappers emit OTel spans |
| Auto user actions | `event_name=faro.user.action` | None |
| Auto perf metrics | `app_memory`, `app_cpu_usage`, `app_frames_rate`, `app_frozen_frame`, `app_startup` | None on iOS; `app.jank` events on Android |
| Crashes | Native crash → `kind=exception, type=crash` (FaroCrashKit) | iOS: MetricKit diagnostics; Android: SDK JVM crash reporting plus demo-owned native crash replay |
| Where to view | Frontend Observability plugin | Same (the collector adds the app labels). Legacy gateway data: [Mobile OTel RUM dashboard](./MOBILE_OTEL_RUM_DASHBOARD.md) |
| User context | `user_id` / `user_username` (Faro auto when set via SDK) | Not on every signal yet; see [M-001](./OTEL_MOBILE_MATURITY.md#m-001--no-first-class-user-context-enduserid-on-mobile-sdks) / [#48](https://github.com/grafana/mobile-o11y-demo/issues/48) |

## The shared Debug screen

Every app has a **Debug** tab for triggering telemetry on demand, with the same
five sections:

1. **Config** — sub-screen for runtime overrides of `BASE_URL`, the Faro
   collector URL or OTLP endpoint, and credentials. Overrides persist locally
   and apply on next launch; a "Restart required" banner shows until then.
2. **Error simulation** — backend toggles sent as headers
   (`x-error-record-recommendation`, `x-delay-record-recommendation`,
   `x-error-get-ingredients`, `x-delay-get-ingredients`), plus client-side
   faults: parse the recommendation with a fake v2 schema, and load tools
   without the auth dependency.
3. **Quick signals** — send a debug log, an error log, and a custom event.
4. **Handled exception** — throws inside `try/catch` and reports it
   (`o11yErrors.reportError` for Faro, `logger.exception(...)` for OTel).
5. **Native crash** — crashes the app natively to exercise crash reporting.

Per-platform extras:

- **Android:** an **OTel SDK** section with a `Disable disk buffering` toggle
  (after restart, export latency drops from the default ~30–45 s to ~1–6 s, at
  the cost of offline resilience) and an **ANR** card that blocks the main
  thread for 10 s.
- **iOS:** a **Crash Reporting** card noting that Apple controls MetricKit
  delivery, so diagnostics may not appear in Grafana Cloud right away.
- **React Native:** client toggles for random frozen frames and memory stress.

Code:

- Flutter — `Mobiles/flutter/lib/features/debug/presentation/debug_screen.dart`
- React Native — `Mobiles/react-native/src/features/debug/presentation/DebugScreen.tsx`
- iOS — `Mobiles/ios/QuickPizzaIos/Features/Debug/Presentation/DebugView.swift`
- Android — `Mobiles/android/app/src/main/java/com/grafana/quickpizza/features/debug/DebugScreen.kt`

OTel SDK gaps (user context, metrics, screen spans) are tracked in
[OTEL_MOBILE_MATURITY.md](./OTEL_MOBILE_MATURITY.md).

## Querying the data

Example `gcx` queries. Substitute your context, data source names, and app IDs.
The raw OTel log query applies to the legacy gateway path; for Faro ingest use
the app-label queries.

```bash
gcx config use-context "<your-stack-context>"

# Faro app discovery
gcx frontend apps list -o json \
  | tail -n +2 | jq -r '.[] | select(.spec.name | test("QuickPizza"; "i")) | "\(.spec.id)\t\(.spec.name)"'

# Signal kinds per day for one app (e.g. app_id=69 Flutter, 123 RN)
gcx logs query -d grafanacloud-logs \
  'sum by (kind) (count_over_time({app_id="69"}[24h]))' \
  --since 168h --step 24h -o json

# Top events
gcx logs query -d grafanacloud-logs \
  'topk(30, sum by (event_name) (count_over_time({app_id="69", kind="event"} | logfmt event_name [24h])))' \
  --since 168h --step 24h -o json

# Native app spans
gcx traces query -d grafanacloud-traces \
  '{resource.service.name="quickpizza-ios"}' --since 168h --limit 200 -o json
gcx traces query -d grafanacloud-traces \
  '{resource.service.name="quickpizza-android"}' --since 720h --limit 200 -o json

# Raw OTel log event names (gateway path)
gcx logs query -d grafanacloud-logs \
  'sum by (event_name) (count_over_time({service_name="quickpizza-android"}[24h]))' \
  --since 720h --step 24h -o json
```

For deeper investigation, the `debug-faro-app` Claude skill (Faro side) and
`gcx skills install debug-with-grafana` (OTel side) both apply.

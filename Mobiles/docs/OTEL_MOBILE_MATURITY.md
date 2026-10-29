# OTel Mobile Maturity Log

Gaps and rough edges hit while using `opentelemetry-swift`,
`opentelemetry-android`, and related contrib packages in the native QuickPizza
apps. Each entry is concrete and reproducible, so it can become an upstream
issue or PR instead of a fork, and so "is OTel mobile mature enough?" gets an
honest answer.

This file covers OTel only. Entries describe this demo's pinned configuration; an open
entry does not prove every current upstream SDK lacks the capability.

## Entries

### M-001 — No first-class user context (`enduser.id`) on mobile SDKs

- **Status:** open
- **Category:** missing-capability
- **Severity:** medium
- **SDKs affected:** `opentelemetry-swift`, `opentelemetry-android`
- **Demo apps affected:** iOS native, Android native
- **First seen:** 2026-05-06

**What we wanted to do**

After login, attach the application user ID to **every** span and log record,
so dashboards can slice telemetry by user, as the Faro mobile SDKs do through
`Faro.setUserMeta(...)`.

**What's missing**

Neither native demo configures app-wide user enrichment for login and logout.
The title keeps the original `enduser.id` wording; current semantic
conventions define `user.id` and `user.name`
([registry](https://opentelemetry.io/docs/specs/semconv/registry/attributes/user/)).
Mutable user context belongs on individual signals (processors or dynamic
attribute suppliers), not on the resource created at startup. `session.id`
already works this way through `Sessions` on iOS and the RUM agent on Android.

**Workaround in this demo**

None yet. Both apps set `user.name` on the manual `auth.login` span only. On
Android, the local package's `globalAttributesSupplier` is a candidate
integration point to evaluate before adding custom processors.

**What we'd want upstream**

A small opt-in user-context library, analogous to `Sessions`:

- A thread-safe holder for the current user ID (plus optional pseudo ID and
  name), set and cleared by app code on login and logout.
- A `SpanProcessor` and `LogRecordProcessor` pair that stamps `user.id` from
  the holder on `onStart` / `onEmit`.
- Privacy-conscious defaults that prefer a pseudonymous identifier over a raw
  username.

The Swift instrumentation package already ships `Sessions` and
`MetricKitInstrumentation`; a user-context module could follow that pattern.

**Tracking**

- Internal: [#48](https://github.com/grafana/mobile-o11y-demo/issues/48)
- Upstream: TBD, after the in-app version settles the API shape.

### M-002 — No OTel metrics export in the native demos

- **Status:** open
- **Category:** missing-capability (demo integration)
- **Severity:** medium-low (workarounds via logs/spans exist)
- **SDKs affected:** `opentelemetry-swift`, `opentelemetry-android`
- **Demo apps affected:** iOS native, Android native
- **First seen:** 2026-05-06

**What we wanted to do**

Emit application metrics (counters, histograms, such as recommendations
requested or latency distributions) through the OTel Metrics SDK, so they land
in Mimir next to infrastructure metrics.

**What's missing**

iOS registers trace and log providers only. The Android local Grafana package
calls `disableMetrics()` after applying upstream configuration, because Faro
OTLP ingest accepts only logs and traces. These are limits of the demo's
configuration, not proof that the underlying SDKs lack a Metrics API.

**Workaround in this demo**

Flutter and React Native send Faro performance measurements as Loki records,
plus custom ones such as `pizza.rating`. These aggregate with LogQL but are not Prometheus metrics. iOS
sends MetricKit data as spans; Android emits jank events.

**Before adding metrics**

- Check the pinned Swift SDK's Metrics API and exporter support for the needed
  instruments and aggregation.
- Choose an endpoint that accepts OTLP metrics and configure export
  explicitly; the Android package disables metrics even when an upstream
  customization sets a metrics endpoint.

**Tracking**

- Internal: TBD
- Upstream: TBD, after a specific SDK limitation is verified.

### M-003 — Android RUM agent's processor extensibility (needs verification)

- **Status:** needs-verification
- **Category:** awkward-api (suspected)
- **Severity:** unknown until verified
- **SDKs affected:** `opentelemetry-android` (the RUM agent specifically)
- **Demo apps affected:** Android native
- **First seen:** 2026-05-06

**What we wanted to do**

Register a custom `SpanProcessor` and `LogRecordProcessor` on the RUM agent
while keeping its auto-instrumentation (HTTP, lifecycle, jank, ANR, crash).

**What's missing**

The demo initializes through the local `GrafanaOtel` package and the upstream
`OpenTelemetryRumInitializer` DSL. The package exposes `globalAttributes` and
`globalAttributesSupplier`, so dynamic attribute enrichment works without
rebuilding providers. Whether arbitrary processors can be registered through
this path still needs a focused check; the lower-level upstream builder and
the DSL expose different customization surfaces.

**Workaround in this demo**

No custom processor is installed. For user enrichment, evaluate the
`globalAttributesSupplier` hook in
[`GrafanaOtelUpstreamConfiguration`](../android/grafana-opentelemetry-android/src/main/java/com/grafana/opentelemetry/android/GrafanaOtel.kt)
first.

**What we'd want upstream (if confirmed)**

Documentation for adding custom span and log processors while keeping the
RUM agent's default instrumentation.

**Tracking**

- Internal: related to [#48](https://github.com/grafana/mobile-o11y-demo/issues/48)
- Upstream: TBD, after verifying the API surface against the pinned version.

### M-004 — Screen / view transitions are not captured as spans

- **Status:** open
- **Category:** missing-capability (with iOS/Android asymmetry)
- **Severity:** low (workarounds exist; both apps emit screen-view log
  events: `app.screen.view` on iOS, `app.navigation.complete` on Android)
- **SDKs affected:** the SwiftUI and Compose configurations used by these demos
- **Demo apps affected:** iOS native, Android native
- **First seen:** 2026-05-06

**What we wanted to do**

Capture each screen visit as a **span** with start, end, and duration,
correlated by `session.id`, so time-per-screen queries work in Tempo without
reconstructing durations from log timestamps.

**What's missing**

- iOS: no automatic SwiftUI screen spans are configured. The
  `.trackScreenView()` modifier emits `app.screen.view` log records.
- Android: SDK screen detection covers Activities and Fragments, as `screen.name`
  on spans (always `MainActivity` in this single-Activity app); it emits no
  `screen.view` event.
  [`MainActivity.kt`](../android/app/src/main/java/com/grafana/quickpizza/MainActivity.kt)
  attaches Compose navigation tracking with `navController.withOpenTelemetry(rum)`,
  which emits `app.navigation.complete` log events with
  `app.navigation.destination.name` set to the route pattern.

Neither app creates a duration span per SwiftUI or Compose screen visit.

**Workaround in this demo**

The log events above. A fuller workaround would be a `ViewModifier` that
starts a span in `onAppear` and ends it in `onDisappear`, at the cost of
per-screen boilerplate; not implemented.

**What we'd want upstream**

- `opentelemetry-swift` (or contrib): an opt-in SwiftUI screen-tracking module,
  for example a `.trackedAsScreen("name")` modifier, since SwiftUI views are
  too granular to treat every body re-render as a screen.
- `opentelemetry-android` RUM agent: screen-duration semantics for the Compose
  navigation integration, including how screen spans relate to user actions
  and sessions.

**Tracking**

- Internal: TBD (promote to a GitHub issue if the demo-side workaround is
  implemented)
- Upstream: TBD

## Adding an entry

1. Take the next free `M-NNN`. Never reuse or renumber IDs.
2. Copy the template below. Be concrete: link a file and line, an upstream
   issue, or a `gcx` query, so the next reader can reproduce it.
3. If you're unsure it's a real gap, file it as `needs-verification` rather
   than dropping it.
4. When an entry resolves, set its status to `resolved` or `upstreamed`. Do
   not delete it.

```markdown
### M-NNN — Short title

- **Status:** open | needs-verification | upstreamed | resolved
- **Category:** missing-capability | awkward-api | bug | docs-gap
- **Severity:** low | medium | high
- **SDKs affected:** opentelemetry-swift, opentelemetry-android, ...
- **Demo apps affected:** iOS native, Android native, ...
- **First seen:** YYYY-MM-DD

**What we wanted to do**

**What's missing**

**Workaround in this demo**

**What we'd want upstream**

**Tracking**
- Internal: #N
- Upstream: <link or TBD>
```

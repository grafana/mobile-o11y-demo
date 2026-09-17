# OTel Mobile Maturity Log

A living log of rough edges, gaps, and contribution opportunities we hit while
using `opentelemetry-swift`, `opentelemetry-android`, and the related contrib
packages in the QuickPizza mobile demo apps.

The point of this file is **not** to complain about the SDKs — they are
genuinely useful and we use them on purpose. The point is to capture concrete,
reproducible friction so that:

1. Future demo work has a list of "things that hurt last time, watch out."
2. We have evidence to drive **upstream contributions** instead of forking. Each
   entry is a candidate issue / PR / RFC against the corresponding upstream
   project.
3. SEs and customers asking "is OTel mobile mature enough for us?" get an
   honest, current answer instead of a marketing one.

Faro mobile SDK quirks live in the per-platform READMEs and in the
[overview's "Known issues" section](./MOBILE_OBSERVABILITY_OVERVIEW.md#known-issues--open-questions).
This file is OTel-mobile-specific. Entries retain their original IDs and
first-seen dates. The 2026-09-17 review checks the demo source and pinned
configuration; an open entry is not evidence that every current upstream SDK
lacks the capability.

## Entry format

Each entry has a stable ID (`M-NNN`) so issues, PRs, and commits can reference
it. New entries are appended — do not renumber existing ones.

```
### M-NNN — Short title

- **Status:** open | needs-verification | upstreamed | resolved
- **Category:** missing-capability | awkward-api | bug | docs-gap
- **Severity:** low | medium | high
- **SDKs affected:** opentelemetry-swift, opentelemetry-android, ...
- **Demo apps affected:** iOS native, Android native, ...
- **First seen:** YYYY-MM-DD

**What we wanted to do**
[concrete user-story-shaped sentence]

**What actually happened / what's missing**
[the gap]

**Workaround in this demo (if any)**
[code pointer or "none yet"]

**What we'd want upstream**
[shape of the proposed change — be specific]

**Tracking**
- Internal: #N
- Upstream: <link or TBD>
```

---

## Entries

### M-001 — No first-class user context (`enduser.id`) on mobile SDKs

- **Status:** open
- **Category:** missing-capability
- **Severity:** medium
- **SDKs affected:** `opentelemetry-swift`, `opentelemetry-android`
- **Demo apps affected:** iOS native, Android native
- **First seen:** 2026-05-06

**What we wanted to do**

After login, attach the application user ID (`user.id` in current OTel semantic
conventions) to **every** span and log record the SDK produces, so dashboards can slice
telemetry by user — the same way the Faro mobile SDKs do automatically via
`Faro.setUserMeta(...)`.

**What actually happened / what's missing**

Neither native demo configures app-wide user enrichment for login and logout.
The entry title retains the original `enduser.id` wording. The current
[user attribute registry](https://opentelemetry.io/docs/specs/semconv/registry/attributes/user/)
also defines `user.id` and `user.name`; the demo uses `user.name` for login.
Choose the identifier deliberately when implementing app-wide context.
Mutable user context belongs on individual signals, for example through
processors or dynamic attribute suppliers, rather than on the SDK resource
created at startup.

This is the same shape as `session.id`, which the SDKs *do* solve via the
`Sessions` library on iOS and the RUM agent on Android. So the precedent for
"per-signal mutable context" exists — user context is the obvious next one.

**Workaround in this demo (if any)**

None yet. Both apps set `user.name` on the manual `auth.login` span. They do
not attach the logged-in user to every span or log record. The Android local
package exposes `globalAttributesSupplier`, which is a possible integration
point to evaluate before adding custom processors.

**What we'd want upstream**

A small, opt-in user-context library analogous to `Sessions`:

- `UserContextHolder` (or similar) — thread-safe holder for current user id +
  optional pseudo id and full name. Set/cleared by app code on login/logout.
- A pre-built `SpanProcessor` and `LogRecordProcessor` pair that read from the
  holder and stamp `user.id` on `onStart` / `onEmit`.
- Privacy-conscious defaults that avoid collecting a raw username when a
  pseudonymous identifier meets the application's needs.

The Swift instrumentation package already supplies `Sessions` and
`MetricKitInstrumentation`; a user-context module could follow that pattern.

**Tracking**

- Internal: [#48](https://github.com/grafana/mobile-o11y-demo/issues/48)
- Upstream: TBD — open after we've shipped the in-app version and know the API
  shape we want.

---

### M-002 — No OTel metrics export in the native demos

- **Status:** open
- **Category:** missing-capability (demo integration)
- **Severity:** medium-low (workarounds via logs/spans exist)
- **SDKs affected:** `opentelemetry-swift`, `opentelemetry-android`
- **Demo apps affected:** iOS native, Android native
- **First seen:** 2026-05-06

**What we wanted to do**

Emit application metrics (counters, histograms — e.g. "pizza recommendations
requested", "checkout latency distribution") via the OTel Metrics SDK so they
land in Mimir / Prometheus and show up alongside our infra metrics.

**What actually happened / what's missing**

The iOS setup registers trace and log providers only. The Android local
Grafana package explicitly calls `disableMetrics()` after applying upstream
configuration because its Faro OTLP ingest path accepts logs and traces.
These are limits of this demo's configuration, not evidence that Android's
underlying OTel SDK lacks a Metrics API.

**Workaround in this demo (if any)**

Flutter and React Native emit Faro performance measurements as Loki records.
React Native also emits the custom `pizza.recommendation` and `pizza.rating`
measurements. Flutter's business measurement adapter is a console-only no-op.
These values can be aggregated with LogQL, but they are not Prometheus metrics.
iOS exposes MetricKit performance data as spans; Android emits jank events.

**What needs verification before adding metrics**

- Check the pinned Swift SDK's Metrics API and exporter support against the
  required instruments and aggregation behavior.
- Choose an endpoint that accepts OTLP metrics and explicitly configure metric
  export; the Android package currently disables it even when an upstream
  customization specifies a metrics endpoint.
- Keep any upstream capability gap separate from the demo's ingest and setup
  choices.

**Tracking**

- Internal: TBD
- Upstream: TBD — verify a specific SDK limitation before opening an issue.

---

### M-003 — Android RUM agent's processor extensibility (needs verification)

- **Status:** needs-verification
- **Category:** awkward-api (suspected)
- **Severity:** unknown until verified
- **SDKs affected:** `opentelemetry-android` (the RUM agent specifically)
- **Demo apps affected:** Android native
- **First seen:** 2026-05-06

**What we wanted to do**

Register a custom `SpanProcessor` and `LogRecordProcessor` on the RUM agent
without bypassing it (so we keep the agent's auto-instrumentation: HTTP,
lifecycle, jank, ANR, crash).

**What actually happened / what's missing**

The demo initializes through the local `GrafanaOtel` package and the upstream
`OpenTelemetryRumInitializer` DSL. The local package exposes
`globalAttributes` and `globalAttributesSupplier`, so dynamic attribute
enrichment has a configuration hook without rebuilding providers.

Arbitrary custom processor registration through this initialization path
still needs a focused check. Do not infer that it requires losing the agent's
auto-instrumentation: the lower-level upstream builder and the initialization
DSL expose different customization surfaces.

**Workaround in this demo (if any)**

No custom processor is installed. For user enrichment, first evaluate the
existing `globalAttributesSupplier` hook in
[`GrafanaOtelUpstreamConfiguration`](../android/grafana-opentelemetry-android/src/main/java/com/grafana/opentelemetry/android/GrafanaOtel.kt).

**What we'd want upstream (if confirmed)**

Document how to add custom span and log processors while retaining the RUM
agent's default instrumentation. Verify the pinned version before proposing
an API.

**Tracking**

- Internal: related to [#48](https://github.com/grafana/mobile-o11y-demo/issues/48)
- Upstream: TBD — verify the API surface first, then file an issue against
  `opentelemetry-android` if needed.

---

### M-004 — Screen / view transitions are not captured as spans

- **Status:** open
- **Category:** missing-capability (with iOS/Android asymmetry)
- **Severity:** low (workarounds exist; we already emit `screen.view`-shaped
  signals)
- **SDKs affected:** the SwiftUI and Compose configurations used by these demos
- **Demo apps affected:** iOS native, Android native
- **First seen:** 2026-05-06

**What we wanted to do**

Capture each screen the user visits as a **span**, with start / end / duration,
correlated with the user's `session.id`. A session ID is not a parent span ID.
Screen-duration spans support time-per-screen queries in Tempo without
reconstructing durations from log timestamps.

**What actually happened / what's missing**

- iOS: the demo does not configure automatic SwiftUI screen-duration spans.
  Its `.trackScreenView()` modifier emits `app.screen.view` log records.
- Android: SDK screen detection covers Activities and Fragments. The Compose
  demo bridges route changes manually with `TrackScreenViews` in
  [`MainActivity.kt`](../android/app/src/main/java/com/grafana/quickpizza/MainActivity.kt),
  emitting `app.screen.view` with `app.screen.name`,
  `nav.previous_destination`, and `nav.kind`.

Neither app creates a duration span for each SwiftUI or Compose screen visit.
This does not claim that every upstream UI instrumentation lacks spans.

**Workaround in this demo (if any)**

Both demos emit manual `app.screen.view` logs for their declarative UI routes.
Android also retains the SDK's Activity/Fragment screen instrumentation.

A more thorough workaround would be a custom `ViewModifier` that calls
`onAppear` to start a span and `onDisappear` to end it — at the cost of
boilerplate on every screen. We have not implemented this.

**What we'd want upstream**

- `opentelemetry-swift` (or contrib): a SwiftUI screen-tracking module that
  uses `ViewModifier`s to emit a span per screen-presentation. Probably needs
  to be opt-in per screen (or a single `.trackedAsScreen("name")` modifier)
  rather than fully automatic, since SwiftUI views are too granular to
  treat every body re-render as a screen.
- `opentelemetry-android` RUM agent: provide a documented Compose navigation
  integration with screen-duration semantics, including how screen spans
  relate to user actions and sessions.

**Tracking**

- Internal: TBD (this entry; promote to a GitHub issue if/when we decide to
  implement the demo-side workaround)
- Upstream: TBD

---

## How to add a new entry

1. Pick the next free `M-NNN` (do not reuse / renumber).
2. Use the template at the top of this file.
3. Be concrete: link to file:line, an upstream issue, a `gcx` query — anything
   that lets a future reader reproduce what you saw.
4. If you don't yet know whether something is a real gap, file it with status
   `needs-verification` rather than dropping it. The verification is worth as
   much as the entry itself.
5. When an entry resolves (upstream PR merged, in-app workaround obsoleted,
   etc.), set the status to `resolved` or `upstreamed` — do **not** delete
   it. The history of "things we hit and how they got fixed" is the most
   useful part of this file long-term.

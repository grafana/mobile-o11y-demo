# Connect a QuickPizza Mobile App to Grafana Cloud

This is the single place that explains how to point any of the QuickPizza
mobile apps at a Grafana Cloud stack. The apps split into two telemetry
families that authenticate differently:

| Apps | SDK family | What you configure | Where the data lands |
| --- | --- | --- | --- |
| Flutter, React Native | Grafana **Faro** | `FARO_COLLECTOR_URL` | Frontend Observability plugin |
| iOS native, Android native | **OpenTelemetry** | `OTLP_ENDPOINT` | Frontend Observability plugin |

Both families reach the same place. The Faro apps post Faro payloads to
`/collect/<appKey>`; the native OTel apps post OTLP/HTTP to `/otlp/<appKey>` on
the same collector, which translates OTLP to Faro on the way in. Each app has
its own key, so each shows up as its own app in the plugin.

> **Faro OTLP ingest runs on development collectors only.** The
> `/otlp/<appKey>` route is not enabled in production yet — a production
> collector returns `404` on that path today. The demo stack uses a development
> collector for this reason.

A legacy option remains for the native apps: export to the Grafana Cloud OTLP
gateway. That path lands **raw OTel** in Tempo and Loki, and the Frontend
Observability plugin cannot read it, so you query it with the
[Mobile OTel RUM dashboard](./MOBILE_OTEL_RUM_DASHBOARD.md). It also needs
`OTLP_INSTANCE_ID` and `OTLP_API_KEY` — see
[Alternative: the OTLP gateway](#alternative-the-otlp-gateway) below.

> **Faro apps require a collector URL.** The Flutter and React Native apps
> throw at startup if `FARO_COLLECTOR_URL` is empty, so you must set it (see
> below) even for a local-only demo. The **native OTel apps (iOS, Android)** are
> different — they still run with the OTLP fields empty. On iOS (debug builds)
> spans go to the Xcode console; on Android export is disabled (the SDK runs as
> a noop, so no OTel signals are produced). Set the OTLP fields when you want
> data in Grafana.

Every app can also take these values at runtime from its in-app **Debug →
Config** screen (applied on next launch), so you can reconfigure during a demo
without rebuilding.

## This doc is about the *mobile app's* telemetry, not the backend's

The mobile apps send their telemetry **directly** to Grafana Cloud (Faro
collector or OTLP gateway) — the QuickPizza backend is not in that path and
needs no configuration for the apps to report. Everything below configures the
app, not the backend.

The backend emits its **own** traces/metrics/logs (via Grafana Alloy), which is
what you need if you want to see the **server side** of the HTTP calls the apps
make — i.e. mobile → backend end-to-end traces in one stack. That is configured
separately, not here: run the backend with the instrumented Docker Compose setup
and a `.env` containing `GRAFANA_CLOUD_STACK` + `GRAFANA_CLOUD_TOKEN`, then turn
on the relevant solutions as documented in the root README under
[*Enable Grafana Cloud Observability solutions*](../../README.md#enable-grafana-cloud-observability-solutions)
(and the Docker Compose `.env` steps just above it). Point the backend at the
**same** Grafana Cloud stack as the app so both land together.

---

## Faro apps (Flutter, React Native)

Faro apps send to a **collector URL** that already encodes the app identity and
auth — there is no separate token to manage. This URL is **required**: the
Flutter and React Native apps throw at startup if it is empty.

1. In Grafana Cloud, open **Frontend Observability**.
2. Create a new app (or open an existing one) and set the domain — for local
   demos `http://localhost:3333` is fine.
3. Copy the app's **Faro collector URL** (looks like
   `https://faro-collector-<region>.grafana.net/collect/<token>`).
4. Put it in the app's `config.json` as `FARO_COLLECTOR_URL` (see the
   [Flutter](../flutter/README.md) / [React Native](../react-native/README.md)
   READMEs for the exact file location).

The app then appears in the Frontend Observability plugin. On the demo stack
these are registered as `QuickPizza_Flutter` and `QuickPizza_ReactNative`.

---

## OpenTelemetry apps (iOS native, Android native)

OTel apps send OTLP/HTTP to the **Faro collector**, which translates OTLP to
Faro and registers the app in Frontend Observability. The app key sits in the
URL path, so there is no separate token to manage.

### Find your endpoint

1. In Grafana Cloud, open **Frontend Observability**.
2. Create a new app (or open an existing one).
3. Copy the app's **Faro collector URL** (looks like
   `https://faro-collector-<region>.grafana.net/collect/<appKey>`).
4. Replace `/collect/` with `/otlp/` to get the Faro OTLP ingest URL:

```
https://faro-collector-<region>.grafana.net/otlp/<appKey>
```

> **Development collectors only.** This route is not enabled in production yet.
> A production collector returns `404` on `/otlp/<appKey>`, and the exporter
> then drops every signal. The demo apps target a development collector for this
> reason.

Leave `OTLP_INSTANCE_ID` and `OTLP_API_KEY` empty — the apps send no
`Authorization` header when either value is blank.

> **Every signal needs a `session.id`.** When the collector runs with session
> management on, it rejects an OTLP request that carries a signal without one:
> `400 session.id is required on every signal`. Both native apps track sessions
> and stamp the attribute, so this only bites a hand-rolled OTLP client.

On the demo stack these are registered as `QuickPizza_Android` and
`QuickPizza_iOS`.

### Where to put them

| App | Config location |
| --- | --- |
| iOS native | `Mobiles/ios/Config.xcconfig` (`OTLP_ENDPOINT`, `OTLP_INSTANCE_ID`, `OTLP_API_KEY`) — see [iOS README](../ios/README.md) |
| Android native | `Mobiles/android/app/src/main/res/raw/config.json` (same three keys) — see [Android README](../android/README.md) |

Use the OTLP base URL **without** a trailing slash or `/v1/traces` suffix — the
signal paths (`/v1/traces`, `/v1/logs`) get appended for you: the iOS app builds
them itself, and on Android the OpenTelemetry SDK exporter handles them.

### View the data

The app appears in the **Frontend Observability** plugin, next to the Flutter
and React Native apps.

> **Android latency note:** the OTel-Android SDK buffers exports to disk
> (~30–45 s) for offline resilience. For live demos, flip **Debug →
> OpenTelemetry SDK → Disable disk buffering** to drop latency to ~1–6 s.

### Alternative: the OTLP gateway

This is the legacy path. Prefer Faro OTLP ingest above — unless you need the
Mobile OTel RUM dashboard, or you target a production stack, where the
`/otlp/<appKey>` route is not enabled yet.

The gateway bypasses the collector, so nothing translates the payloads. The data
stays **raw OTel**: Loki streams carry `service_name` and `service_namespace`
only, with no `app_id`, `app_key`, or `kind` label. The Frontend Observability
plugin keys off those labels, so it **cannot read gateway data** — the apps do
not appear in the plugin at all. The
[Mobile OTel RUM dashboard](./MOBILE_OTEL_RUM_DASHBOARD.md) exists for this path.

To use it, point the apps at the Grafana Cloud OTLP gateway:

```
https://otlp-gateway-<clusterSlug>.grafana.net/otlp
```

This path authenticates with an **instance ID + access token**:

1. Go to your Grafana Cloud org page (`https://grafana.com/orgs/<your-org>`).
2. Open the stack — the **cluster slug** and **numeric Instance ID** are listed
   on its details page.
3. Generate an **Access Policy token** with scopes `metrics:write`,
   `logs:write`, `traces:write` (the native apps need logs + traces; metrics is
   harmless to include).

Put all three values in the same config file. The app computes
`Authorization: Basic base64(instanceId:apiKey)` for you.

Traces then appear in **Explore → Tempo** within seconds (filter by
`resource.service.name="quickpizza-ios"` / `"quickpizza-android"`); logs in
**Explore → Loki** (`service_name="quickpizza-ios"` / `"quickpizza-android"`).

---

## Troubleshooting

**No data in Grafana**

- Confirm the telemetry values are set (in `config.json` / `Config.xcconfig`, or
  the Debug → Config overrides) and you relaunched the app.
- Faro: confirm the collector URL is complete (includes the `/collect/<token>`
  path).
- OTel: confirm the endpoint is OTLP/**HTTP** (not gRPC) and has no trailing
  slash. For Faro OTLP ingest, confirm the URL ends with `/otlp/<appKey>`. For
  the OTLP gateway, confirm the token allows `logs:write` + `traces:write`.
- Use the in-app **Debug** tab to emit a test log / handled exception and
  confirm it arrives.

For what each app actually emits and how to query it, see
[`MOBILE_OBSERVABILITY_OVERVIEW.md`](./MOBILE_OBSERVABILITY_OVERVIEW.md).

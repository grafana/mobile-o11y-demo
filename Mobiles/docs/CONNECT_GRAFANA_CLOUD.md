# Connect a QuickPizza Mobile App to Grafana Cloud

This is the single place that explains how to point any of the QuickPizza
mobile apps at a Grafana Cloud stack. The apps split into two telemetry
families that authenticate differently:

| Apps | SDK family | What you configure | Where the data lands |
| --- | --- | --- | --- |
| Flutter, React Native | Grafana **Faro** | `FARO_COLLECTOR_URL` | Frontend Observability plugin |
| iOS native, Android native | **OpenTelemetry** | `OTLP_ENDPOINT` + `OTLP_INSTANCE_ID` + `OTLP_API_KEY` | Tempo (traces) + Loki (logs), viewed via the [Mobile OTel RUM dashboard](./MOBILE_OTEL_RUM_DASHBOARD.md) |

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

OTel apps send OTLP/HTTP to the Grafana Cloud OTLP gateway and authenticate
with an **instance ID + access token**.

### Find your endpoint and credentials

The OTLP endpoint follows the standard Grafana Cloud pattern:

```
https://otlp-gateway-<clusterSlug>.grafana.net/otlp
```

To find `clusterSlug`, the numeric Instance ID, and a token:

1. Go to your Grafana Cloud org page (`https://grafana.com/orgs/<your-org>`).
2. Open the stack — the **cluster slug** and **numeric Instance ID** are listed
   on its details page.
3. Generate an **Access Policy token** with scopes `metrics:write`,
   `logs:write`, `traces:write` (the native apps need logs + traces; metrics is
   harmless to include).

The app computes `Authorization: Basic base64(instanceId:apiKey)` for you — you
only supply the three raw values.

### Where to put them

| App | Config location |
| --- | --- |
| iOS native | `Mobiles/ios/Config.xcconfig` (`OTLP_ENDPOINT`, `OTLP_INSTANCE_ID`, `OTLP_API_KEY`) — see [iOS README](../ios/README.md) |
| Android native | `Mobiles/android/app/src/main/res/raw/config.json` (same three keys) — see [Android README](../android/README.md) |

Use the OTLP base URL **without** a trailing slash or `/v1/traces` suffix — the
signal paths (`/v1/traces`, `/v1/logs`) get appended for you: the iOS app builds
them itself, and on Android the OpenTelemetry SDK exporter handles them.

### View the data

Traces appear in **Explore → Tempo** within seconds (filter by
`resource.service.name="quickpizza-ios"` / `"quickpizza-android"`); logs in
**Explore → Loki** (`service_name="quickpizza-ios"` / `"quickpizza-android"`).
For a RUM-style view, import the
[Mobile OTel RUM dashboard](./MOBILE_OTEL_RUM_DASHBOARD.md).

> **Android latency note:** the OTel-Android SDK buffers exports to disk
> (~30–45 s) for offline resilience. For live demos, flip **Debug →
> OpenTelemetry SDK → Disable disk buffering** to drop latency to ~1–6 s.

---

## Troubleshooting

**No data in Grafana**

- Confirm the telemetry values are set (in `config.json` / `Config.xcconfig`, or
  the Debug → Config overrides) and you relaunched the app.
- Faro: confirm the collector URL is complete (includes the `/collect/<token>`
  path).
- OTel: confirm the endpoint is OTLP/**HTTP** (not gRPC), has no trailing slash,
  and the token allows `logs:write` + `traces:write`.
- Use the in-app **Debug** tab to emit a test log / handled exception and
  confirm it arrives.

For what each app actually emits and how to query it, see
[`MOBILE_OBSERVABILITY_OVERVIEW.md`](./MOBILE_OBSERVABILITY_OVERVIEW.md).

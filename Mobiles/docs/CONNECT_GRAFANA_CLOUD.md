# Connect a QuickPizza Mobile App to Grafana Cloud

Every app sends to the Grafana Cloud **Faro collector** and shows up in the
Frontend Observability plugin as its own app:

| Apps | SDK family | Config key | Endpoint |
| --- | --- | --- | --- |
| Flutter, React Native | Grafana Faro | `FARO_COLLECTOR_URL` | `https://faro-collector-<region>.grafana.net/collect/<appKey>` |
| iOS native, Android native | OpenTelemetry | `OTLP_ENDPOINT` | `https://faro-collector-<region>.grafana.net/otlp/<appKey>` |

The app key in the URL identifies the app, so there is no token to manage. The
collector translates native OTLP to Faro on ingest.

The mobile apps send telemetry directly to Grafana Cloud; the QuickPizza
backend is not in that path. To see the server side of the app's HTTP calls
(mobile-to-backend traces), run the backend with the instrumented Docker
Compose setup against the **same** stack. Refer to
[Enable Grafana Cloud Observability solutions](../../README.md#enable-grafana-cloud-observability-solutions)
in the root README.

## Get your collector URL

1. In Grafana Cloud, open **Frontend Observability**.
2. Create an app (or open an existing one). Name it after the demo app —
   `QuickPizza_Flutter`, `QuickPizza_ReactNative`, `QuickPizza_iOS` or
   `QuickPizza_Android`; the Faro apps send that `app_name`. The domain field
   only matters for web apps; any value works for mobile.
3. Copy the app's **Faro collector URL**:
   `https://faro-collector-<region>.grafana.net/collect/<appKey>`.

Create one app per mobile app so each gets its own key. Frontend Observability
shows data under the app registered for the key.

## Faro apps (Flutter, React Native)

Put the collector URL, unchanged, in the app's `config.json` as
`FARO_COLLECTOR_URL`:

| App | Config file |
| --- | --- |
| Flutter | `Mobiles/flutter/config.json` (from `config.json.example`) — see [Flutter README](../flutter/README.md) |
| React Native | `Mobiles/react-native/config.json` (from `config.json.example`) — see [React Native README](../react-native/README.md) |

A URL is required (`FARO_COLLECTOR_URL`, or `FARO_COLLECTOR_URL_IOS` /
`FARO_COLLECTOR_URL_ANDROID` per platform). These apps throw at startup when
none is set.

## OpenTelemetry apps (iOS native, Android native)

Replace `/collect/` with `/otlp/` in the collector URL:

```text
https://faro-collector-<region>.grafana.net/otlp/<appKey>
```

Set it as `OTLP_ENDPOINT` and leave `OTLP_INSTANCE_ID` and `OTLP_API_KEY`
empty. The apps send no `Authorization` header when either value is blank.

| App | Config file |
| --- | --- |
| iOS native | `Mobiles/ios/Config.xcconfig` (from `Config.xcconfig.example`) — see [iOS README](../ios/README.md) |
| Android native | `Mobiles/android/app/src/main/res/raw/config.json` (from `config.json.example`) — see [Android README](../android/README.md) |

Rules for the endpoint:

- Use the base URL **without** a `/v1/traces` or `/v1/logs` suffix. The local
  Grafana OpenTelemetry package on each platform appends the signal paths, and
  the iOS package rejects an endpoint that already ends in one.
- A `404` from `/otlp/<appKey>` means the URL is wrong, or native mobile OTLP
  ingest is not enabled for that stack. Compare the URL with the app's setup
  page in Frontend Observability first. The apps don't surface export errors
  in the UI; look in the iOS console (`OTel SDK:` lines) or Android logcat.
- With the OTLP fields empty, the apps run but OpenTelemetry is not initialized
  and sends nothing.

The collector rejects OTLP signals without a `session.id` when session
management is on (`400 session.id is required on every signal`). Both native
apps stamp it on every span and log; this matters only if you reuse the
endpoint from your own OTLP client.

**Export latency:** both native apps buffer to disk, so signals can take tens
of seconds to arrive. On Android, enable **Debug → OpenTelemetry SDK → Disable
disk buffering** and restart the app for faster export, at the cost of offline
persistence. iOS has no runtime toggle.

## Change config at runtime

Every app's **Debug → Config** screen overrides these values without a rebuild.
Overrides apply on the next launch.

## Alternative: the OTLP gateway

Legacy path for the native apps. Use it only if you need the
[Mobile OTel RUM dashboard](./MOBILE_OTEL_RUM_DASHBOARD.md).

The gateway bypasses the Faro collector, so data lands as **raw OTel** in Tempo
and Loki with no app identity labels (`app_id`, `app_key`, `kind`). The
Frontend Observability plugin cannot read it, and the apps do not appear there.

Point `OTLP_ENDPOINT` at:

```text
https://otlp-gateway-<regionSlug>.grafana.net/otlp
```

This path needs an instance ID and access token:

1. Open your Grafana Cloud org page (`https://grafana.com/orgs/<your-org>`).
2. Open the stack's **OpenTelemetry** tile. It shows the exact gateway URL and
   the numeric **Instance ID**. The gateway uses the stack's region
   (`regionSlug`), which can differ from its cluster (`clusterSlug`).
3. Create an **Access Policy token** with `logs:write` and `traces:write`
   (`metrics:write` is harmless).

Set `OTLP_INSTANCE_ID` and `OTLP_API_KEY` in the same config file. The app
builds `Authorization: Basic base64(instanceId:apiKey)` itself.

Query the data in **Explore**: Tempo with
`{resource.service.name="quickpizza-ios"}` (or `quickpizza-android`), Loki with
`{service_name="quickpizza-ios"}`.

## Troubleshooting

No data in Grafana:

- Confirm the values are set in the config file or Debug → Config, and that
  you relaunched the app.
- Faro: confirm the URL is complete, including `/collect/<appKey>`.
- OTel: confirm the endpoint is OTLP/**HTTP** (not gRPC), is the base URL (not
  a `/v1/...` signal URL), and ends with `/otlp/<appKey>` for Faro ingest.
- OTLP gateway: confirm the token allows `logs:write` and `traces:write`.
- Use the in-app **Debug** tab to send a test log or handled exception, then
  look for it.

What each app emits and how to query it:
[MOBILE_OBSERVABILITY_OVERVIEW.md](./MOBILE_OBSERVABILITY_OVERVIEW.md).

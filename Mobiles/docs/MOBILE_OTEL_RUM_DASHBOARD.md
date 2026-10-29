# Mobile OTel RUM Dashboard

A reusable dashboard for native Android and iOS apps that send OpenTelemetry
logs and traces through the **legacy OTLP gateway**. That path lands raw OTel
in Loki and Tempo, which the Frontend Observability plugin cannot read; this
dashboard queries it directly. For the preferred Faro collector path and the
gateway setup, see [Connect to Grafana Cloud](./CONNECT_GRAFANA_CLOUD.md).

## Requirements

- Grafana 13 or later. The JSON uses the dashboard resource format and a
  tabbed layout
  ([dynamic dashboards](https://grafana.com/whats-new/2026-04-08-dynamic-dashboards-is-now-generally-available/)).
- A stack receiving native app logs and traces through the OTLP gateway,
  shaped like the QuickPizza demo apps.
- A Loki data source named `grafanacloud-logs` and a Tempo data source named
  `grafanacloud-traces`. Your stack may use names such as
  `grafanacloud-<stack>-logs`; update the references after import.

## Import the dashboard

1. Open your Grafana stack and go to **Dashboards**.
2. Select **New** → **Import dashboard**.
3. Upload or paste `Mobiles/dashboards/mobile-otel-rum-dashboard.json`.
4. Save.

To manage it as code, push the JSON resource with `gcx` or Git Sync.

## Configure mobile service names

The custom multi-value variable `service_name` (**Mobile service names**)
lists the OTel `service.name` values to show. It defaults to the demo values
`quickpizza-android, quickpizza-ios`; replace them with your own, for example:

```text
my-app-android, my-app-ios
```

The list is manual because stacks usually hold backend services in the same
data sources. You can also type a name into the dropdown.

## Select a session

Select a row in **Sessions — click to select**, or enter an exact **Session
ID**. Log detail panels filter on an exact match; leaving it blank does not
mean "all sessions". The trace panel uses a session ID prefix match. Overview
panels aggregate across the selected services and time range.

The session list is built from Android `rum.sdk.init.started` and iOS
`session.start` events. An Android session that starts after initialization
can have telemetry but no row; enter its ID directly.

## Telemetry the dashboard expects

- Resource attributes `service.name`, `service.namespace`, `service.version`.
  The dashboard does not filter on deployment environment.
- `session.id` on signals, queried in Loki as `session_id`.
- Android `device.crash` and `device.anr` events for the crash panels. Android
  keeps these names by disabling the SDK's latest experimental semantic
  conventions.

The full event inventory per platform is in
[MOBILE_OBSERVABILITY_OVERVIEW.md](./MOBILE_OBSERVABILITY_OVERVIEW.md#per-platform-telemetry-inventory).

**Crashes**, **Crash-Free Sessions**, and **ANRs** count only Android events.
iOS MetricKit diagnostics appear in **Events** and **Session Timeline** for the
selected session, so a zero crash count does not prove an iOS session had no
crash.

## Troubleshooting

If the dashboard is empty:

- Check that the time range contains recent telemetry.
- Check that **Mobile service names** matches your app's `service.name`.
- Select a session for log detail panels. If its startup event is outside the
  time range, widen the range or enter the session ID directly.
- Check that the app exports OTLP over HTTP to the gateway, with a token that
  allows `logs:write` and `traces:write`.
- Check that the dashboard points at the right Loki and Tempo data sources.

To generate data, use the Debug tab: on Android, a debug log, handled
exception, ANR, or crash; on iOS, logs and handled exceptions. Apple controls
MetricKit delivery, and SDK disk buffering delays export, so records can take
a while to become queryable.

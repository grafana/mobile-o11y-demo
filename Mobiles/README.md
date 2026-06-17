# QuickPizza Mobile Demos

**Start here.** This directory holds four mobile QuickPizza apps used to demo
mobile observability with Grafana. They share the same screens and talk to the
same backend — what differs is the telemetry SDK and where the data lands.

This page is the entry point: it tells you **which platforms are supported**,
**how to get a demo running**, and **where to go for more detail**. Everything
deeper lives in linked docs so the same information isn't repeated in five
places.

---

## Supported platforms

| Platform | Type | Location | SDK | Data lands in | Run guide |
| --- | --- | --- | --- | --- | --- |
| **Flutter** (Android + iOS) | Cross-platform | [`flutter/`](./flutter/) | Grafana **Faro** | Frontend Observability | [Flutter README](./flutter/README.md) |
| **React Native** (Android + iOS) | Cross-platform | [`react-native/`](./react-native/) | Grafana **Faro** | Frontend Observability | [React Native README](./react-native/README.md) |
| **iOS native** (SwiftUI) | Native | [`ios/`](./ios/) | **OpenTelemetry** Swift | Tempo + Loki | [iOS README](./ios/README.md) |
| **Android native** (Compose) | Native | [`android/`](./android/) | **OpenTelemetry** Android | Tempo + Loki | [Android README](./android/README.md) |

Two telemetry stories, one backend:

- **Faro** (Flutter, React Native) → exports to the Grafana Cloud **Frontend
  Observability** plugin.
- **OpenTelemetry** (iOS, Android) → exports OTLP/HTTP to **Tempo + Loki**,
  visualized with the [Mobile OTel RUM dashboard](./docs/MOBILE_OTEL_RUM_DASHBOARD.md).

For a side-by-side of what each app actually emits, see
[`docs/MOBILE_OBSERVABILITY_OVERVIEW.md`](./docs/MOBILE_OBSERVABILITY_OVERVIEW.md).

---

## Run a demo in 3 steps

### Step 1 — Start the backend

All four apps need the QuickPizza backend. The simplest way is one container:

```bash
docker run --rm -d --name quickpizza -p 3333:3333 \
  ghcr.io/grafana/quickpizza-mobile-local:latest
```

Verify it's up:

```bash
curl http://localhost:3333/api/pizza   # should return a JSON pizza
```

> Use the `quickpizza-mobile-local` image for mobile work. The upstream
> `quickpizza-local` image is reserved for the k6/web workshops. To run the
> backend with full local/cloud observability instead, see the Docker Compose
> options in the [root README](../README.md).

### Step 2 — Connect to Grafana Cloud

Whether this is optional depends on the SDK family:

- **Flutter / React Native (Faro):** a `FARO_COLLECTOR_URL` is **required** —
  these apps throw at startup without one, even for a local-only demo.
- **iOS / Android native (OpenTelemetry):** Grafana Cloud is **optional** —
  leave the OTLP fields empty to keep telemetry in the local console, or set
  them to export.

One doc covers both: [**Connect to Grafana Cloud**](./docs/CONNECT_GRAFANA_CLOUD.md)
(Faro collector URL and OTLP endpoint/token).

### Step 3 — Pick a platform and run it

Each app has the toolchain prerequisites and full instructions in its README.
Quick orientation:

- **iOS native** — lightest path on a Mac (Xcode + Docker only).
  `cd ios && cp Config.xcconfig.example Config.xcconfig && bash Scripts/sim-run.sh`.
  Full steps: [iOS README](./ios/README.md).
- **Android native** — Android Studio + emulator.
  `cd android && cp config.json.example app/src/main/res/raw/config.json && ./gradlew installDebug`.
  Full steps: [Android README](./android/README.md) ·
  [toolchain setup](./docs/ANDROID_NATIVE_SETUP.md).
- **Flutter** — needs the Flutter SDK plus a mobile toolchain:
  [Flutter README](./flutter/README.md) ·
  [Android toolchain](./docs/FLUTTER_ANDROID_SETUP.md) ·
  [iOS toolchain](./docs/FLUTTER_IOS_SETUP.md).
- **React Native** — needs Node ≥ 24.5 + Yarn (and CocoaPods for iOS):
  [React Native README](./react-native/README.md).

> First-time mobile toolchain setup (Xcode ~15 GB, Android Studio + SDK, or the
> Flutter/Node toolchains) can take an hour or more if you've never done mobile
> development. The backend (Step 1) is the only part that's instant.

---

## Shared basics

These apply to every app, so they're stated once here.

- **Login:** username `default`, password `12345678`.
- **Backend URL on emulators/simulators:** leave `BASE_URL` empty — the apps
  auto-resolve to `http://10.0.2.2:3333` on Android emulators (which routes to
  your host) and `http://localhost:3333` on the iOS simulator. For a **physical
  device**, set `BASE_URL` to your machine's LAN IP (e.g.
  `http://192.168.1.100:3333`) and make sure the device is on the same network.
- **Debug tab (the demo driver):** every app has an in-app **Debug** screen to
  override config at runtime, inject backend errors/latency, and trigger test
  logs, handled exceptions, and native crashes — this is how you generate
  telemetry on demand during a demo. Details and per-platform extras are in
  [`docs/MOBILE_OBSERVABILITY_OVERVIEW.md § The shared Debug screen`](./docs/MOBILE_OBSERVABILITY_OVERVIEW.md#the-shared-debug-screen).

---

## Where to go for more

| I want to… | Read |
| --- | --- |
| Understand what each app emits and where it lands | [`docs/MOBILE_OBSERVABILITY_OVERVIEW.md`](./docs/MOBILE_OBSERVABILITY_OVERVIEW.md) |
| Send a mobile app's telemetry to a Grafana Cloud stack (the app's own Faro / OTLP config) | [`docs/CONNECT_GRAFANA_CLOUD.md`](./docs/CONNECT_GRAFANA_CLOUD.md) |
| See the shared screens & workflows spec | [`FEATURES.md`](./FEATURES.md) |
| Import the native OTel RUM dashboard | [`docs/MOBILE_OTEL_RUM_DASHBOARD.md`](./docs/MOBILE_OTEL_RUM_DASHBOARD.md) |
| Deep-dive iOS OTel instrumentation | [`docs/IOS_OBSERVABILITY_OTEL_GUIDE.md`](./docs/IOS_OBSERVABILITY_OTEL_GUIDE.md) |
| Understand the iOS app architecture | [`docs/IOS_APP_ARCHITECTURE.md`](./docs/IOS_APP_ARCHITECTURE.md) |
| Run the cross-platform E2E tests | [`e2e/README.md`](./e2e/README.md) |
| Track OTel mobile SDK gaps / contributions | [`docs/OTEL_MOBILE_MATURITY.md`](./docs/OTEL_MOBILE_MATURITY.md) |

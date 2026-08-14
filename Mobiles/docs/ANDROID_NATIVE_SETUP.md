# Android Native Setup Guide

Setup guide for the native Android QuickPizza app (`Mobiles/android/`).

> Companion docs:
> - New here? Start at the [Mobile README](../README.md) for the all-apps overview.
> - For the cross-platform observability overview (what each mobile app emits, where it lands), see [`MOBILE_OBSERVABILITY_OVERVIEW.md`](./MOBILE_OBSERVABILITY_OVERVIEW.md).
> - For a higher-level Android README (features + quickstart + config reference), see [`../android/README.md`](../android/README.md).
> - For the **Flutter** Android emulator setup, see [`FLUTTER_ANDROID_SETUP.md`](./FLUTTER_ANDROID_SETUP.md).

---

## Prerequisites

- [Android Studio](https://developer.android.com/studio) (Hedgehog 2023.1.1+ recommended)
- Android SDK with at least API 23 (Android 6.0 Marshmallow) — the app's `minSdk`
- A running QuickPizza backend (see root README)

---

## 1. Create your config file

The app reads `app/src/main/res/raw/config.json` at startup. This file is gitignored so you must create it from the example:

```bash
cp Mobiles/android/config.json.example \
   Mobiles/android/app/src/main/res/raw/config.json
```

Edit `config.json`:

```json
{
  "OTLP_ENDPOINT": "https://faro-collector-<region>.grafana.net/otlp/<appKey>",
  "OTLP_INSTANCE_ID": "",
  "OTLP_API_KEY": "",
  "BASE_URL": ""
}
```

The app key in the path identifies the app, so the instance ID and token stay
empty, and the app appears in Frontend Observability. This route runs on
development collectors only for now — a production collector returns `404`. For
what each field means, see the
[config reference in the Android README](../android/README.md#configuration-reference).
To obtain the OTLP endpoint — or to send to the Grafana Cloud OTLP gateway
instead — see
[Connect to Grafana Cloud](./CONNECT_GRAFANA_CLOUD.md#opentelemetry-apps-ios-native-android-native).
For `BASE_URL` emulator/device defaults (and why Android uses `10.0.2.2` rather
than `localhost`), see [Shared basics](../README.md#shared-basics).

> All four fields can also be overridden at runtime from the in-app
> **Debug → Config** screen without rebuilding. Overrides take effect after the
> next app restart.

---

## 2. Open the project in Android Studio

```
File → Open → select Mobiles/android/
```

Android Studio will sync the Gradle project automatically.

---

## 3. Run on the Android Emulator

### Option A — Android Studio

1. Create a Virtual Device: **Tools → Device Manager → Create Device**
   - Recommended: Pixel 6, API 35
2. Click **Run ▶** (Shift+F10)

### Option B — Command line

```bash
cd Mobiles/android
./gradlew installDebug
adb shell am start -n com.grafana.quickpizza/.MainActivity
```

---

## 4. Run on a physical device

1. Enable **Developer Options** and **USB Debugging** on the device
2. Connect via USB and accept the debug prompt
3. Set `BASE_URL` in `config.json` to your machine's LAN IP:
   ```json
   { "BASE_URL": "http://192.168.1.100:3333" }
   ```
4. Run from Android Studio or `./gradlew installDebug`

---

## Observability

The app uses [opentelemetry-android](https://github.com/open-telemetry/opentelemetry-android)
and exports via OTLP/HTTP. The signals it produces, the resource attributes, and
the `OTelService` wiring are documented in the
[Android README § Observability](../android/README.md#observability); the
cross-platform comparison (how this differs from iOS, Flutter, and React Native)
is in [`MOBILE_OBSERVABILITY_OVERVIEW.md`](./MOBILE_OBSERVABILITY_OVERVIEW.md).

---

## Troubleshooting

**Build fails with `ClassNotFoundException` or dex errors**
Ensure `gradle.properties` has `android.useFullClasspathForDexingTransform=true` (required by opentelemetry-android with AGP 8.3+).

**App can't reach the backend**
- Emulator: Make sure QuickPizza is running on the host and `BASE_URL` is empty (uses `10.0.2.2:3333`)
- Physical device: Set `BASE_URL` to your machine's LAN IP

**No telemetry in Grafana**
- Check `OTLP_ENDPOINT`, `OTLP_INSTANCE_ID`, and `OTLP_API_KEY` in `config.json` (or the
  overrides set via the in-app **Debug → Config** screen)
- Verify the endpoint accepts OTLP HTTP (not gRPC)
- Use the **Debug** tab to trigger a test debug log, custom event, or
  handled exception and confirm they arrive

**Telemetry arrives slowly (~30–45 s lag)**
- This is the OTel-Android SDK's disk-buffering window — by design, so signals survive offline periods.
- For live demos, flip **Debug → OpenTelemetry SDK → Disable disk buffering** ON. Latency drops to ~1–6 s, but signals are dropped if the app is offline. Restart the app for the toggle to take effect.

## In-app Debug screen

The **Debug** tab (runtime config overrides, error/latency injection, the disk
buffering toggle, quick signals, handled exception, ANR, and crash cards) is
documented in the [Android README § Features](../android/README.md#features).

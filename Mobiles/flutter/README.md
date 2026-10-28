# QuickPizza Flutter app

The QuickPizza mobile app in Flutter, for Android and iOS, instrumented with the
Grafana Faro Flutter SDK. It sends telemetry to a Faro collector, where it shows
up in Frontend Observability as `QuickPizza_Flutter`.

> **New here?** Start at [`../README.md`](../README.md) for the backend, login and
> the other three apps. Screens and workflows are in [`../FEATURES.md`](../FEATURES.md);
> what this app emits is in
> [`../docs/MOBILE_OBSERVABILITY_OVERVIEW.md`](../docs/MOBILE_OBSERVABILITY_OVERVIEW.md).

## Prerequisites

- A Flutter SDK that bundles Dart 3.12 or later, the floor set by
  [`pubspec.lock`](pubspec.lock). `flutter --version` prints the Dart version.
- `python3` on your `PATH`, used by `scripts/run-*.sh`.
- A running QuickPizza backend ([`../README.md`](../README.md#run-a-demo-in-3-steps)).
- A Faro collector URL ([Connect to Grafana Cloud](../docs/CONNECT_GRAFANA_CLOUD.md)).
- Android: Android Studio with SDK Platform-Tools, Emulator and Command-line
  Tools, plus at least one AVD. The compile SDK follows your Flutter SDK
  (`flutter.compileSdkVersion`).
- Android: **JDK 17**. This project's Gradle 8.14 does not run on the JDK 25 that
  recent Android Studio versions bundle; Flutter reports a Java/Gradle
  incompatibility. Point Flutter at a JDK 17 with `flutter config --jdk-dir`
  (below). The setting is global to your Flutter SDK.
- iOS (macOS only): Xcode with an iOS simulator runtime. The deployment target is
  iOS 15.0.

One-time toolchain setup:

```bash
# Android
flutter config --jdk-dir <path-to-jdk-17>
flutter config --android-sdk ~/Library/Android/sdk   # if flutter doctor can't find the SDK
flutter doctor --android-licenses

# iOS
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch

flutter doctor   # Android toolchain and Xcode should both pass
```

See Flutter's [Android](https://docs.flutter.dev/platform-integration/android/setup)
and [iOS](https://docs.flutter.dev/platform-integration/ios/setup) setup guides
if `flutter doctor` still complains.

## Configure

```bash
# From the repository root:
cd Mobiles/flutter
flutter pub get
cp config.json.example config.json   # gitignored
```

Edit `config.json`:

| Key | Value |
| --- | --- |
| `FARO_COLLECTOR_URL` | **Required** unless a platform key below or a saved Debug → Config URL is set. Your Faro collector URL, ending in `/collect/<appKey>`. The app throws at startup when no URL is set. |
| `FARO_COLLECTOR_URL_IOS`, `FARO_COLLECTOR_URL_ANDROID` | Optional. Override `FARO_COLLECTOR_URL` on one platform, for example to send each platform to its own Frontend Observability app. |
| `BASE_URL` | Backend URL. Leave empty on emulators and simulators (`http://10.0.2.2:3333` on Android, `http://localhost:3333` on iOS, using `PORT`). On a physical device, use your machine's LAN IP, for example `http://192.168.1.100:3333`. |
| `PORT` | Backend port when `BASE_URL` is empty. Defaults to `3333`. |
| `CI_DEMO_VERSIONING` | CI only. Leave `false`. |

A collector or backend URL set in the in-app **Debug → Config** screen
overrides `config.json` after an app restart.

## Run

```bash
./scripts/run-android.sh   # uses a connected Android device, or launches the first AVD
./scripts/run-ios.sh       # boots an iPhone simulator and opens Simulator (DeviceHub on Xcode 27)
```

Both scripts run [`../telemetry/flutter-config.py`](../telemetry/flutter-config.py),
which picks the config file (`QUICKPIZZA_FLUTTER_CONFIG_FILE` if set, else the
active dual-stack config, else `config.json`), checks that it parses as JSON and
passes it to `flutter run`. It does not check the URLs. `run-ios.sh` always targets a
simulator and ignores connected iPhones. For a physical iPhone, or any other
device, run Flutter directly:

```bash
flutter devices
flutter run -d "<device-id>" --dart-define-from-file=config.json
```

A physical iPhone needs code signing: open `ios/Runner.xcworkspace` in Xcode, pick your team
under **Runner → Signing & Capabilities**, and change the bundle id
(`com.example.flutterMobileO11yDemo`) if Xcode reports it as unavailable.

To start a simulator yourself on Xcode 27, where `open -a Simulator` no longer
works, use `../scripts/open-simulator.sh`. For an Android emulator, use
`flutter emulators --launch "<emulator-id>"`.

In VS Code or Cursor, open the repository root and use the **Flutter (debug)**
launch configuration from [`.vscode/launch.json`](../../.vscode/launch.json).

The project has no web target: Faro's HTTP instrumentation uses `dart:io`.

**Dual-stack telemetry:** while [dual-stack telemetry](../telemetry/README.md) is
active, the helper scripts and the VS Code launch configurations use its
generated backend and collector settings, and return to `config.json` after
teardown. For a manual run, pass
`--dart-define-from-file=../telemetry/.runtime/active/flutter.json`.

## Generating telemetry

Use the in-app **Debug** tab to override config, inject backend errors and
latency, send test logs and events, throw handled and unhandled exceptions, and
trigger native crashes on Android and iOS (through the `MethodChannel`-based
`NativeCrashService`). See
[the shared Debug screen](../docs/MOBILE_OBSERVABILITY_OVERVIEW.md#the-shared-debug-screen).

## How Faro is wired

[`lib/bootstrap.dart`](lib/bootstrap.dart) starts telemetry in this order (arguments trimmed):

```dart
WidgetsFlutterBinding.ensureInitialized();
installFaroHttpOverrides();   // before any http.Client exists
...
await startDemoRum(appRunner: () async {
  await startFaro(appRunner: () => runApp(
    UncontrolledProviderScope(container: container,
      child: wrapWithDemoRum(wrapWithFaro(const QuickPizzaApp()))),
  ));
});
```

- **HTTP:** `installFaroHttpOverrides()` sets `HttpOverrides.global`. An
  `http.Client` created before that call bypasses Faro for good, so it runs first.
- **Config** ([`faro_init.dart`](lib/core/o11y/faro/faro_init.dart)):
  `appName: 'QuickPizza_Flutter'`; `apiKey` is the `<appKey>` parsed from the
  collector URL, so you set only the URL; `enableCrashReporting: true` (native
  crashes are sent on the next launch; on Android this needs API 30+); `sampling: SamplingRate(...)`, from
  Debug → Config (default `1.0`); CPU, memory, refresh-rate and ANR vitals.
- **Offline:** an `OfflineTransport` caches signals for up to 3 days and sends
  them when the device is back online.
- **Widgets and routes:** `wrapWithFaro` adds `FaroAssetTracking` and
  `FaroUserInteractionWidget`. The router registers `FaroNavigationObserver` on
  the root and shell navigators.

## A second RUM SDK next to Faro (DemoRum)

The app also runs **DemoRum**, a made-up, no-op RUM SDK in
[`lib/core/o11y/demo_rum/`](lib/core/o11y/demo_rum/). It is intentional: it shows
where a second mobile RUM SDK plugs into an app that already uses Faro. Faro is
the only real instrumentation.

- The shared `core/o11y/` layer fans every error, log, event and span out to
  both SDKs. DemoRum sends nothing over the network; it echoes each call to the
  console as `[DemoRum]` logs.
- It installs chained `FlutterError.onError` and `PlatformDispatcher.onError`
  handlers (saving and calling the previous handler), so both SDKs see every Dart
  error. Its HTTP wrapper, `DemoRumHttpClient` (in `demo_rum.dart`, used by
  `api_client.dart`), is an `http.Client` decorator that forwards requests on top of Faro's `HttpOverrides`.
  Its spans run their callbacks, so behavior never changes.
- Nesting is `startDemoRum` → `startFaro` → `runApp`. Both SDKs chain error
  handlers, so the order only decides which runs first.
- To use a real vendor SDK, replace the types in
  `lib/core/o11y/demo_rum/sdk/demo_rum.dart`.
- To check it, use the Debug tab. Its events reach Faro and also appear as
  `[DemoRum]` logs. The **Capture DemoRum Test Exception** button tests the
  manual reporting path.

## Development

**Architecture:** MVVM per feature, under `lib/features/<feature>/` with
`domain/` (repositories, providers), `presentation/` (screens, ViewModels,
widgets) and `models/` (plain data classes). Shared infrastructure is in
`lib/core/` (config, o11y, router, theme, localization). ViewModels are Riverpod
`Notifier`s that expose a UI state class plus an `Actions` interface, so widgets
never touch `.notifier`. For an example, see
[`rating_buttons_view_model.dart`](lib/features/pizza/presentation/widgets/rating_buttons_view_model.dart).

**Icon and splash:** after changing images in `assets/`, regenerate the
platform resources (config is in `pubspec.yaml`):

```bash
dart run flutter_launcher_icons          # assets/icon.png, assets/icon_ios.png
dart run flutter_native_splash:create    # assets/splash.png
```

**Versioning:** bump `version` in `pubspec.yaml` for significant changes. Faro
reports it as the app version.

**Symbols:** the app is not built with `--obfuscate` or `--split-debug-info`, so
Dart stack traces arrive readable. The repo has no Flutter symbol upload; if you
add obfuscation, keep the split debug info to read the traces yourself.

### AI-assisted testing with MCP

An AI assistant can drive the running app through the Dart MCP server:

1. Launch with Flutter Driver enabled: use the **Flutter (debug with driver)**
   launch configuration, or run
   `flutter run --dart-define-from-file=config.json lib/driver_main.dart`.
2. Copy the Dart Tooling Daemon (DTD) URI from the Debug Console, or use
   **Copy DTD URI to clipboard** in VS Code or Cursor. It looks like
   `ws://127.0.0.1:61788/Jc_1sL6labM=`.
3. Give the URI to the assistant. It can then tap, type, scroll and inspect the
   widget tree.

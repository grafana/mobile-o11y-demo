# QuickPizza React Native app

The QuickPizza mobile app in React Native, for Android and iOS, instrumented with
the Grafana Faro React Native SDK. It sends telemetry to a Faro collector, where
it shows up in Frontend Observability as `QuickPizza_ReactNative`.

> **New here?** Start at [`../README.md`](../README.md) for the backend, login and
> the other three apps. Screens and workflows are in [`../FEATURES.md`](../FEATURES.md);
> what this app emits is in
> [`../docs/MOBILE_OBSERVABILITY_OVERVIEW.md`](../docs/MOBILE_OBSERVABILITY_OVERVIEW.md).

## Prerequisites

- Node.js 24.5+ and Yarn 4 through Corepack (both pinned in
  [`package.json`](package.json)). With nvm: `nvm install 24 && nvm use 24`.
- The [React Native environment](https://reactnative.dev/docs/set-up-your-environment)
  for Android (Android Studio, SDK, an AVD) and/or iOS (Xcode, CocoaPods).
- Android: **JDK 17**. This project's Gradle 8.13 rejects the JDK 25 that recent
  Android Studio versions bundle (`Unsupported class file major version 69`).
  Point `JAVA_HOME` at a JDK 17, for example
  `export JAVA_HOME=$(/usr/libexec/java_home -v 17)` on macOS.
- iOS: deployment target iOS 15.1.
- A running QuickPizza backend ([`../README.md`](../README.md#run-a-demo-in-3-steps)).
- A Faro collector URL ([Connect to Grafana Cloud](../docs/CONNECT_GRAFANA_CLOUD.md)).

## Configure

```bash
# From the repository root:
cd Mobiles/react-native
corepack enable
yarn install --immutable
cp config.json.example config.json   # gitignored
cd ios && bundle install && bundle exec pod install && cd ..   # iOS only; Gemfile pins CocoaPods
```

CocoaPods needs a UTF-8 locale. If `pod install` fails with an encoding error,
run `export LANG=en_US.UTF-8` first.

Edit `config.json`:

| Key | Value |
| --- | --- |
| `FARO_COLLECTOR_URL` | **Required** unless the platform key below is set. Your Faro collector URL, ending in `/collect/<appKey>`. When no URL is set, the app fails at launch (red-screen error in debug builds), even with a Debug override. |
| `FARO_COLLECTOR_URL_IOS` / `FARO_COLLECTOR_URL_ANDROID` | Optional per-platform URL; wins over `FARO_COLLECTOR_URL` on that platform. |
| `BASE_URL` | Backend URL. Leave empty on emulators and simulators (`http://10.0.2.2` on Android, `http://localhost` on iOS). |
| `PORT` | Backend port when `BASE_URL` is empty. Defaults to `3333`. |

Metro bundles `config.json` into the JavaScript, so after editing it restart
Metro (`yarn start --reset-cache`) and reload the app. The in-app
**Debug → Config** screen can override the backend and collector URLs; saved
overrides win over `config.json` from the next launch.

**Physical devices:**

- **iOS:** set `BASE_URL` to your machine's LAN IP, for example
  `http://192.168.1.100:3333`. Local-network HTTP is allowed
  (`NSAllowsLocalNetworking`). Pick your signing team in
  `ios/QuickPizza.xcworkspace` under **QuickPizza → Signing & Capabilities**.
- **Android:** cleartext HTTP is only allowed to `10.0.2.2`, `10.0.3.2`,
  `localhost` and `127.0.0.1`
  ([`network_security_config.xml`](android/app/src/main/res/xml/network_security_config.xml)),
  so a LAN-IP HTTP URL is blocked. Over USB, run `adb reverse tcp:3333 tcp:3333`
  and set `BASE_URL` to `http://127.0.0.1:3333`. Otherwise use an HTTPS backend,
  or add your IP to that file.

## Run

```bash
yarn start            # Metro, in its own terminal

yarn android          # or ./scripts/run-android.sh, which boots an emulator if none is connected
yarn ios              # or ./scripts/run-ios.sh
```

`yarn android` / `yarn ios` start Metro if it is not already running.
`yarn android` sets up `adb reverse` for Metro's port 8081 itself.
While [dual-stack telemetry](../telemetry/README.md) is active, Metro bundles its
config instead of `config.json` (`metro.config.js` switches on every start), so
edits to `config.json` are ignored.

## How Faro is initialized

`App.tsx` loads the config and Debug overrides, then calls `initFaro()` in
[`src/bootstrap.ts`](src/bootstrap.ts). That function makes one
`initializeFaro({...})` call from `@grafana/faro-react-native`; there is no
separate instrumentation list. Features are config flags (abridged):

```ts
const faro = await initializeFaro({
  app: { name: 'QuickPizza_ReactNative', version: APP_VERSION, environment: APP_ENV },
  url: collectorUrl,                  // .../collect/<appKey>
  apiKey,                             // the <appKey> segment of the URL
  sessionTracking: { enabled: true, persistent: false, sampling: new SamplingRate(1) },
  cpuUsageVitals: true, memoryUsageVitals: true, refreshRateVitals: true,
  anrTracking: true,                  // Android only
  enableErrorReporting: true,
  enableCrashReporting: true,         // native crashes, sent on next launch
  enableTracing: true,                // HTTP spans + traceparent
  tracingOptions: {
    instrumentationOptions: { propagateTraceHeaderCorsUrls: getQuickPizzaTracePropagationUrlPatterns() },
  },
} as ReactNativeConfig);
```

- `@grafana/faro-react-native-tracing` only needs to be installed: with
  `enableTracing: true` the SDK loads it itself.
- `traceparent` goes only to the backend URL and local backend hosts. For one trace
  from app to backend in Tempo, run the backend with
  `QUICKPIZZA_TRUST_CLIENT_TRACEID=true` (set in the `compose.grafana-*.yaml` files).
- `initializeFaro` is async and returns `undefined` when Faro is already
  registered. After init the app sends a `faro_initialized` event.
- Custom measurements use `faro.api.pushMeasurement` through
  [`src/core/o11y/o11yMetrics.ts`](src/core/o11y/o11yMetrics.ts).

## Telemetry notes

- Use the in-app **Debug** tab to generate telemetry: test logs, the
  `debug_custom_event` custom event, handled and unhandled exceptions, backend
  error injection, and native crashes. Native crashes arrive on the next launch
  as `kind=exception, type=crash` (on Android, API 30+ only). See
  [the shared Debug screen](../docs/MOBILE_OBSERVABILITY_OVERVIEW.md#the-shared-debug-screen).
- The app name `QuickPizza_ReactNative` is set in
  [`src/bootstrap.ts`](src/bootstrap.ts).
- Release builds need source maps to show readable JavaScript stack traces. See
  [`SOURCE_MAPS.md`](SOURCE_MAPS.md).

## E2E tests

The shared [Arbigent](../e2e/README.md) runner drives this app. With the backend
running and the app installed on an emulator:

```bash
export OPENAI_API_KEY='<your-key>'
../e2e/run_e2e_tests.sh --app=react-native --platform=android
```

See [`../e2e/README.md`](../e2e/README.md) for iOS, results and options.

## Troubleshooting

- **`Faro is already registered` in logs:** fully restart the app.
  `src/bootstrap.ts` guards repeat calls within one module instance, but Fast
  Refresh can reload the module while the global Faro instance stays registered.
- **Stale JavaScript after changes:** restart Metro with `yarn start --reset-cache`.
- **Android install or storage errors:** run `./scripts/clean-and-reinstall.sh`
  (add `--wipe-emulator` to reset the emulator). See
  [`../scripts/ANDROID_STORAGE_FIX.md`](../scripts/ANDROID_STORAGE_FIX.md).

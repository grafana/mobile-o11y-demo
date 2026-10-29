# QuickPizza Android Demo App

A native Kotlin / Jetpack Compose app that exports traces and logs over OTLP/HTTP with the
[opentelemetry-android](https://github.com/open-telemetry/opentelemetry-android) RUM agent. For the
other three apps and the backend, start at [`../README.md`](../README.md).

## Prerequisites

- [Android Studio](https://developer.android.com/studio) recent enough to open an AGP 9.1 project
  (see the [AGP / Studio compatibility table](https://developer.android.com/build/releases/gradle-plugin#android_gradle_plugin_and_android_studio_compatibility)).
  Older releases such as Hedgehog cannot open it.
- JDK 17 or newer to run Gradle (AGP 9.1 and Gradle 9.3 both require it). Android Studio's bundled
  JDK works. For command-line builds, point `JAVA_HOME` at it if your system JDK is older.
- Android SDK platform 37 (`compileSdk`). Devices need API 23 or newer (`minSdk`).
- A running QuickPizza backend, started as described in [`../README.md`](../README.md).

SDK versions are pinned in [`gradle/libs.versions.toml`](gradle/libs.versions.toml).

## Configure

```bash
cd Mobiles/android
cp -n config.json.example app/src/main/res/raw/config.json
```

`config.json` is gitignored. To send to Frontend Observability, set `OTLP_ENDPOINT` to your Faro
collector's OTLP route and leave the credentials empty:

```json
{ "OTLP_ENDPOINT": "https://faro-collector-<region>.grafana.net/otlp/<appKey>" }
```

Telemetry then appears in Frontend Observability under the app you registered for the key
(`QuickPizza_Android` on the demo stack). How to find the URL, and
the legacy OTLP gateway alternative, are in
[Connect to Grafana Cloud](../docs/CONNECT_GRAFANA_CLOUD.md#opentelemetry-apps-ios-native-android-native).

### Configuration reference

| Field | Description |
| --- | --- |
| `OTLP_ENDPOINT` | OTLP/HTTP base URL, without `/v1/traces` or `/v1/logs`. Empty disables export. |
| `OTLP_INSTANCE_ID` | Numeric OTLP gateway instance ID. Legacy gateway only; leave empty for Faro. |
| `OTLP_API_KEY` | Grafana Cloud access token, combined with the instance ID into `Authorization: Basic`. Legacy gateway only. |
| `BASE_URL` | QuickPizza backend URL. Empty resolves to `http://10.0.2.2:3333` (the emulator's host). For devices, see [Run on a physical device](#run-on-a-physical-device). |

All four fields can be overridden from **Debug → Config** without a rebuild. Overrides persist and
apply after you restart the app.

> [!WARNING]
> If `QUICKPIZZA_ANDROID_CONFIG_FILE` is set, or `Mobiles/telemetry/.runtime/active/android.json`
> exists (left by the [dual-stack setup](../telemetry/README.md)), the build packages that file
> instead of `res/raw/config.json`, and your edits are ignored. The environment variable wins over
> the runtime file.

Precedence: **Debug → Config** override > that alternate file > `res/raw/config.json`. Overrides
survive `installDebug`; reset them with **Reset All** on the Debug tab or **Use defaults** on the
Config screen.

## Run on an emulator

In Android Studio: **File → Open → `Mobiles/android/`**, create a virtual device in
**Tools → Device Manager** (Pixel 6, API 35 works well), then **Run**.

From the command line, with an emulator running:

```bash
cd Mobiles/android
./gradlew installDebug
adb shell am start -n com.grafana.quickpizza.android/com.grafana.quickpizza.MainActivity
```

## Run on a physical device

1. Enable **Developer Options** and **USB debugging** on the device, connect it over USB and accept
   the prompt.
2. On API 24 or newer, forward the backend port and use the device loopback URL:

   ```bash
   adb reverse tcp:3333 tcp:3333
   ```

   Set `BASE_URL` to `http://127.0.0.1:3333`.
3. Run from Android Studio or with `./gradlew installDebug`.

The app allows cleartext HTTP only to `localhost`, `127.0.0.1` and `10.0.2.2`
(`app/src/main/res/xml/network_security_config.xml`), so an HTTP URL to a LAN IP is blocked. Use an
HTTPS backend for remote hosts. API 23 ignores the per-host exceptions, so it needs HTTPS even for
loopback.

## Android-specific Debug tab extras

The shared Debug tab is described in
[MOBILE_OBSERVABILITY_OVERVIEW.md](../docs/MOBILE_OBSERVABILITY_OVERVIEW.md#the-shared-debug-screen).
Android adds:

- **Disable disk buffering** (OpenTelemetry SDK section). Buffering is on by default: about 30-45 s
  end-to-end latency, but signals survive offline periods. Turn it off for live demos (about 1-6 s),
  then restart the app.
- **ANR**: blocks the main thread for 10 s; the agent reports `device.anr`.
- **Crash (RuntimeException)** and **Crash (NPE)**: the agent's `CrashReporter` writes
  `device.crash` and flushes before the process dies. With buffering on, it ships on the next launch.
- **NDK crash (C++ / tombstone)** → **SIGSEGV (null dereference)**: on API 30 and newer, the app-owned `NativeExitCrashReporter` replays the
  native exit as `device.crash` after relaunch.

## Observability

Startup lives in `app/src/main/java/com/grafana/quickpizza/core/o11y/OTelService.kt`, which calls
`GrafanaOtel.initialize` from the local
[Grafana OpenTelemetry Android library](grafana-opentelemetry-android/README.md). The signal and
attribute inventory is in
[MOBILE_OBSERVABILITY_OVERVIEW.md](../docs/MOBILE_OBSERVABILITY_OVERVIEW.md#android-native-opentelemetry-android).

### How telemetry is wired

Kotlin paths are under `app/src/main/java/com/grafana/quickpizza/`.

1. `QuickPizzaApp.onCreate` (`@HiltAndroidApp`) resolves `RuntimeConfigHolder.current`, then calls
   `OTelService.initialize()`. With an empty `OTLP_ENDPOINT` it returns and the app runs with
   `OpenTelemetry.noop()`.
2. `OTelService` passes the `faro.app.bundleId` resource attribute to `GrafanaOtel.initialize`
   (see [Release build and symbols](#release-build-and-symbols)).
3. After init, `OTelService` starts `NativeExitCrashReporter` on a background thread to replay
   native crashes. It reaches the SDK providers by reflection, so keep the `unobfuscate` rules in
   `app/proguard-rules.pro`.
4. `di/AppModule.kt` wraps the OkHttp client:

   ```kotlin
   import io.opentelemetry.instrumentation.okhttp.v3_0.OkHttpTelemetry

   OkHttpTelemetry.create(otelService.openTelemetry).createCallFactory(buildBaseOkHttpClient())
   ```

   `app/build.gradle.kts` also applies the Byte Buddy plugin with the upstream `okhttp3-agent`.
5. `MainActivity` attaches Compose navigation, which emits `app.navigation.complete` log events:

   ```kotlin
   import io.opentelemetry.instrumentation.compose.navigation.withOpenTelemetry

   otelService.openTelemetryRum?.let { navController.withOpenTelemetry(it) }
   ```

Other points specific to this app:

- Sessions use a 15-minute background inactivity timeout and a 4-hour maximum lifetime.
- The app does not set `deployment.environment.name`, so environment filters do not match it.

## Release build and symbols

Release builds use R8 and `ndk.debugSymbolLevel = FULL`. The `com.grafana.faro.android-symbols`
Gradle plugin, wired in `app/build.gradle.kts`, uploads the R8 mapping and
native debug symbols after `assembleRelease`, `bundleRelease` or `installRelease`.

Each release is identified by `applicationId@versionCode@versionName`, by default
`com.grafana.quickpizza.android@1@1.0.0` (`versionName` comes from the `quickpizzaDemoVersionName`
Gradle property). The id is written to `app/build/faro/bundle-id-release.txt`, uploaded with the
symbols and sent at runtime as the `faro.app.bundleId` resource attribute.

The upload reads its credentials from the environment. If any is missing, the upload warns and is
skipped, and the build still succeeds. Set `faro { enabled = false }` to turn uploads off.

| Variable | Source in Grafana |
| --- | --- |
| `FARO_SOURCEMAP_ENDPOINT` | Frontend Observability → your app → **Settings → Source maps** (API base URL) |
| `FARO_SOURCEMAP_APP_ID` | App id |
| `FARO_SOURCEMAP_STACK_ID` | Stack id |
| `FARO_SOURCEMAP_API_KEY` | Upload token |

```bash
cd Mobiles/android
export FARO_SOURCEMAP_ENDPOINT="https://faro-api-<region>.grafana.net/faro/api/v1"
export FARO_SOURCEMAP_APP_ID="<app-id>"
export FARO_SOURCEMAP_STACK_ID="<stack-id>"
export FARO_SOURCEMAP_API_KEY="<token>"
./gradlew installRelease
```

On release, `faroWriteBundleIdRelease` runs before the build and `faroUploadSymbolsRelease` after
it. To check the inputs of a failed upload, look for `[Faro]` lines in the Gradle output and for the
artifacts of the same build:

```bash
ls -l app/build/faro/bundle-id-release.txt
ls -l app/build/outputs/mapping/release/mapping.txt
ls -l app/build/outputs/native-debug-symbols/release/native-debug-symbols.zip
```

To retry outside Gradle, run
[`faro-cli android upload`](https://github.com/grafana/faro-javascript-bundler-plugins/tree/main/packages/faro-cli)
with the same `FARO_SOURCEMAP_*` variables and `--application-id` / `--version-code` /
`--version-name` matching `bundle-id-release.txt`.

To verify, open the app, tap
**Debug → Crash (RuntimeException)** and relaunch. The crash in Frontend Observability should show
real Kotlin file names, not obfuscated ones like `a5.r0`.

### Dependency lockfiles

Every project locks its configurations, including the plugin classpath. After bumping a plugin or
dependency, refresh the lockfiles or Gradle fails with a lock mismatch:

```bash
cd Mobiles/android
./gradlew --write-locks :app:dependencies :grafana-opentelemetry-android:dependencies
```

## Troubleshooting

**No telemetry in Grafana**

- Check `OTLP_ENDPOINT` in `config.json` or **Debug → Config**. The legacy gateway also needs
  `OTLP_INSTANCE_ID` and `OTLP_API_KEY`; the Faro route needs neither.
- The endpoint must accept OTLP over HTTP, not gRPC.
- Send a debug log or handled exception from the Debug tab and confirm it arrives. With disk
  buffering on, allow 30-45 s.

**App can't reach the backend**

- Emulator: leave `BASE_URL` empty and make sure the backend is running on the host.
- Physical device: use `adb reverse` with `http://127.0.0.1:3333`, or an HTTPS backend. See
  [Run on a physical device](#run-on-a-physical-device).

**Build fails with `ClassNotFoundException` or dex errors**

- `gradle.properties` must contain `android.useFullClasspathForDexingTransform=true`, which
  `opentelemetry-android` requires with AGP 8.3 and newer.

**Gradle fails to start or reports an unsupported Java version**

- Run Gradle with JDK 17 or newer, for example Android Studio's bundled JDK.

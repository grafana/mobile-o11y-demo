# Grafana OpenTelemetry Android

**Status:** experimental local module, not published or supported for production use. Usage and
configuration are in the [library README](../android/grafana-opentelemetry-android/README.md).

## Placement decision

The library lives in `Mobiles/android/grafana-opentelemetry-android` and is consumed by the
QuickPizza Android app, which gives it a real application and build without creating an empty
repository. The demo is not its permanent home. Generic SDK and instrumentation work stays in
[`opentelemetry-android`](https://github.com/open-telemetry/opentelemetry-android), and build-time
symbol upload stays in
[`faro-android-gradle-plugin`](https://github.com/grafana/faro-android-gradle-plugin).

The name is **Grafana OpenTelemetry Android**, with `GrafanaOtel.initialize(...)` as the entrypoint.
The library has been extracted to
[grafana/grafana-opentelemetry-android](https://github.com/grafana/grafana-opentelemetry-android)
(no release yet). QuickPizza still builds the local module in this repo, and the two copies can
drift: for example, the standalone library defaults `useLatestExperimentalSemanticConventions` to
`true` (the local module uses `false`), which emits `app.crash` instead of `device.crash`. The Maven
coordinate, release owner and supported upstream version window still need agreement. Once a
release exists, QuickPizza can consume the published AAR instead of the project dependency.

## Package boundary

The library owns only Grafana-specific startup configuration: the OTLP endpoint and headers, disk
buffering defaults, service and extra resource attributes, the semantic-convention choice, and
session timeout defaults. It delegates initialization and instrumentation discovery to the upstream
SDK and returns `OpenTelemetryRum`. It defines no Grafana tracer, logger, span or meter APIs.

The app keeps application-specific behavior: native crash replay, the runtime config UI, business
instrumentation, and OkHttp instrumentation (the `OkHttpTelemetry` wrapper and the Byte Buddy
`okhttp3-agent`). Crash flushing uses the upstream 1.7.0 handler, so the app installs no handler of
its own and emits no duplicate crash event.

Faro OTLP ingest accepts logs and traces only, so the library disables periodic metric export
(`GrafanaOtel.kt`). A production package needs per-signal routing before it can send metrics
elsewhere.

### Instrumentation modules

A new instrumentation is a separate AAR that implements the upstream `AndroidInstrumentation`
interface and registers for `ServiceLoader` discovery. Generic instrumentation belongs upstream. A
Grafana-specific module can be a library dependency when it is part of the default experience, or
added by the app when optional; the upstream agent discovers and installs it either way.

With the pinned upstream version, any instrumentation can be suppressed by name, but there is no
type-safe hook for configuring a third-party module. A configurable Grafana instrumentation needs
explicit configuration forwarding or an upstream extension point before publication.

## Remove the library

1. Replace the module dependency with the upstream `android-agent` dependency.
2. Replace `GrafanaOtel.initialize` with `OpenTelemetryRumInitializer.initialize` and the desired
   exporter configuration.
3. Remove `include(":grafana-opentelemetry-android")` from `settings.gradle.kts` and delete the
   module.
4. Remove the unused Android library plugin alias and the `opentelemetry-android-core` test alias
   from the root build and version catalog.
5. From `Mobiles/android`, run `./gradlew --write-locks :app:dependencies`.
6. Leave application tracer, logger, context propagation and instrumentation calls unchanged.

The removal path still needs an automated build before the portability gate is complete. While the
module exists, use the lockfile command in the [Android README](../android/README.md#dependency-lockfiles).

## Run locally

```bash
cd Mobiles/android
./gradlew :grafana-opentelemetry-android:testDebugUnitTest :app:assembleDebug
./gradlew :app:installDebug
adb logcat -c
adb shell am force-stop com.grafana.quickpizza.android
adb shell am start -W -n com.grafana.quickpizza.android/com.grafana.quickpizza.MainActivity
adb logcat -d -s OTelService:I AndroidRuntime:E '*:S'
```

## Validation results

All runs used ARM64 emulators. Environment-specific stack identifiers are kept out of this repo.

| Date (2026) | Build | Receiver | Result |
| --- | --- | --- | --- |
| Aug 27 | Debug, API 23 and API 35 | Local OTLP | Cold start through the library with disk buffering on. Startup only. |
| Aug 28 (`ba69548`) | Debug, API 35 | Local Faro collector | `202` for logs and traces. Session, startup, screen and HTTP records shared one session ID. Mobile `GET` span connected to backend server and DB spans. Metrics got `400`, so metric export was disabled. |
| Sep 9 (OTel Android 1.7.0) | Debug and minified release, API 35 | Local OTLP | 17 library and 7 app tests, library lint and both builds passed. Pizza trace connected end to end. `RuntimeException` delivered after restart with the original session ID, no duplicate. Release kept all 10 instrumentation providers and the OkHttp HTTP sender (5 service descriptors vs 10 in debug). |
| Sep 9 | Minified release, API 35 | Local OTLP | SIGSEGV replayed once as `device.crash` (`reason=CRASH_NATIVE`) after narrow keep rules for two `unobfuscate()` methods in `app/proguard-rules.pro`. No blanket OTel keep rule. |
| Sep 9 | Minified release, API 23 | Local OTLP | Cold start passed. Export blocked by `usesCleartextTraffic=false`; no API 23 export pass claimed. |
| Oct 27 | Debug, API 35 | Hosted Faro collector | Login, recommendations, rating, Debug logs, custom event and handled exception arrived in Tempo and Loki under `QuickPizza_Android`, with `view_changed` derived by ingest. |

The Sep 9 runs are local OTLP checks, not a fresh Faro collector acceptance test. App lint reports
six API-level errors in `NativeExitCrashReporter`; library lint passes.

To re-check a minified release after a dependency bump, build it (`./gradlew :app:assembleRelease`
from `Mobiles/android`) and confirm R8 kept the ServiceLoader entries. The names come from the
build's own mapping, since R8 renames them:

```bash
APK=app/build/outputs/apk/release/app-release.apk
MAP=app/build/outputs/mapping/release/mapping.txt
svc() { sed -n "s/^$1 -> \(.*\):\$/\1/p" "$MAP"; }
INSTRUMENTATION=$(svc 'io\.opentelemetry\.android\.instrumentation\.AndroidInstrumentation')
OKHTTP_SENDER=$(svc 'io\.opentelemetry\.exporter\.sender\.okhttp\.internal\.OkHttpHttpSenderProvider')

# Instrumentation providers kept (10 on OTel Android 1.7.0)
unzip -p "$APK" "META-INF/services/$INSTRUMENTATION" | wc -l
# The OkHttp OTLP sender must appear in one service descriptor
for f in $(zipinfo -1 "$APK" | grep '^META-INF/services/'); do
  unzip -p "$APK" "$f" | grep -Fxq "$OKHTTP_SENDER" && echo "$f -> $OKHTTP_SENDER"
done
```

An empty variable means the class is missing from the mapping. Then install the release build and
confirm logs and traces still export.

## Gate checklist

- [x] The module compiles as an Android AAR and is consumed by the runnable demo app.
- [x] Configuration validation has focused unit coverage.
- [x] Grafana defaults, additive resources, metrics policy, and upstream override precedence
  have focused mapping coverage that runs in CI.
- [x] Kotlin and Java callers have a source-level startup path.
- [x] The package returns upstream OTel runtime and API types.
- [x] Existing application instrumentation compiles without changes.
- [x] The demo cold-starts through the module on API 23 and Android 15 ARM64 emulators.
- [x] Run the app against Faro Collector and verify required Mobile O11y signals.
- [x] Verify an app-instrumented mobile HTTP span remains connected to the QuickPizza backend trace.
- [x] Build and run a minified release without a blanket OpenTelemetry keep rule, preserve the
  R8-rewritten instrumentation ServiceLoader entries, and observe OTLP log and trace exports.
- [ ] Automate the add/remove build using a supported non-Grafana provider.
- [ ] Agree on the production repository, Maven coordinate, release owner, and support window.
- [ ] Choose and enforce the supported upstream dependency range before publication.
- [ ] Validate a published AAR from a separate Java-only consumer with release minification; a
  same-build project dependency does not exercise Maven metadata or the final public ABI.
- [ ] Decide whether production initialization should rebase on the upstream builder to expose
  provider/exporter hooks without reflection.
- [ ] Add an observable export-health path before production use.
- [ ] Add binary API compatibility validation before publishing a versioned AAR.
- [ ] Document the final public setup, migration, removal, and limitations after runtime validation.

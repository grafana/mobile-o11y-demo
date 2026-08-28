# Android OTel Reference Kit Spike

**Status:** Experimental local module. It is not published or supported for production use.

## Placement decision

The runnable spike lives in `Mobiles/android/grafana-otel-reference-kit` and is consumed by the
existing QuickPizza Android app. This gives the package a real application and build without
creating an empty repository or treating the demo repository as its permanent home.

The demo proves the package boundary but is not the permanent source or release location. Generic
Android SDK and instrumentation work remains in
[`opentelemetry-android`](https://github.com/open-telemetry/opentelemetry-android), while build-time
symbol upload remains in
[`faro-android-gradle-plugin`](https://github.com/grafana/faro-android-gradle-plugin). The final
Grafana-owned runtime location, Maven coordinate, release ownership, automation, and supported
upstream version window require agreement before the module is extracted or published.

## Package boundary

The spike owns only startup configuration that is specific to the Grafana distribution:

- the OTLP endpoint and headers;
- disk buffering defaults;
- service and additional resource attributes;
- the semantic-convention compatibility choice;
- background-session inactivity and maximum-lifetime defaults.

It delegates initialization and instrumentation discovery to the upstream Android SDK and returns
`OpenTelemetryRum`. It does not define Grafana tracer, logger, span, or meter APIs. The optional
configuration callback exposes selected upstream settings and instrumentations through a Grafana
scope. Its `resource {}` actions are additive, and required Grafana service attributes are applied
last.

The app still owns application-specific behavior, including its temporary crash-flush workaround,
native crash replay, runtime config UI, business instrumentation, and automatic OkHttp
instrumentation. The connected HTTP trace below proves those app-owned spans remain connected
through the Reference Kit; the package does not install the Byte Buddy plugin or OkHttp agent.

Faro OTLP ingest currently accepts logs and traces only. The spike therefore disables upstream
periodic metric export rather than repeatedly sending unsupported requests.

## Add and remove

The demo adds the local AAR module as a dependency and replaces its direct
`OpenTelemetryRumInitializer` block with `GrafanaOtelReferenceKit.initialize`. Existing application
instrumentation is unchanged and continues to receive `io.opentelemetry.api.OpenTelemetry`.

To remove the Reference Kit:

1. Replace the module dependency with the upstream `android-agent` dependency.
2. Replace the Reference Kit startup call with `OpenTelemetryRumInitializer.initialize` and the
   desired non-Grafana exporter configuration.
3. Remove `include(":grafana-otel-reference-kit")` from `settings.gradle.kts`, then delete the local
   module.
4. Remove the now-unused Android library plugin alias and `opentelemetry-android-core` test-library
   alias from the root build and version catalog.
5. From `Mobiles/android`, run `./gradlew --write-locks :app:dependencies` to refresh the remaining
   app and buildscript locks.
6. Leave application tracer, logger, context propagation, and instrumentation calls unchanged.

While the local module exists, refresh both dependency lockfiles with
`./gradlew --write-locks :app:dependencies :grafana-otel-reference-kit:dependencies`.

This spike verifies the source boundary, but the removal path still needs an automated build or
fixture before the portability gate can be marked complete.

## Run locally

```bash
cd Mobiles/android
./gradlew :grafana-otel-reference-kit:testDebugUnitTest :app:assembleDebug
./gradlew :app:installDebug
adb logcat -c
adb shell am force-stop com.grafana.quickpizza.android
adb shell am start -W \
  -n com.grafana.quickpizza.android/com.grafana.quickpizza.MainActivity
adb logcat -d -s OTelService:I AndroidRuntime:E '*:S'
```

The app reads its normal `app/src/main/res/raw/config.json`. See
[`Mobiles/android/README.md`](../android/README.md) for configuration and emulator instructions.

### Device smoke result

On August 27, 2026, the demo was installed and cold-started on the
`otel_ci_api23_arm64` API 23 ARM64 and `quickpizza_pixel_35` Android 15 ARM64 emulators with a
local OTLP endpoint. In both cases, the activity started, the app process remained alive, and
`OTelService` reported initialization through the Reference Kit with disk buffering enabled. This
proves the packaged startup path; it does not prove that Faro Collector accepted telemetry.

### Faro Collector runtime result

On August 28, 2026, commit `ba695485c9c9ac7b98df3903054af423c8c5024a` was tested on an Android
15 API 35 ARM64 emulator against a local Faro Collector and QuickPizza backend. After the disk
buffer flushed, Faro Collector returned `202` for both OTLP logs and traces. The translated Loki
records contained:

- `session_start`, `rum.sdk.init.*`, `view_changed`, and `app.screen.view` events;
- an `app_startup` measurement with `coldStart=1`;
- `faro.tracing.fetch` for `GET /api/quotes` with HTTP status `200`;
- the same session ID on the startup, screen, and HTTP records.

The connected trace contained the Android `GET` client span, the QuickPizza `GET /api/quotes`
server span as its child, and the backend `SELECT` span as the server span's child. Faro translation
labels product records with the registered application identity, which may differ from the Android
`service.name` resource value.

The environment-specific stack commands and raw identifiers are intentionally kept outside this
public repository. To repeat the validation against Grafana Cloud, follow
[Connect the Demo Apps to Grafana Cloud](CONNECT_GRAFANA_CLOUD.md), run the app as described above,
and inspect the configured application's logs and traces.

During this run, the Faro OTLP endpoint returned `400` for periodic OTLP metrics because that route
supports logs and traces only. The current spike now disables metric export. A production package
must add explicit per-signal routing before it can send metrics to another endpoint.

### Minified release runtime result

On August 28, 2026, the current PR working tree based on commit
`f55efa561b863e006a08964d882a60947f57bab7` was installed with `:app:installRelease` on the
`quickpizza_pixel_35` Android 15 API 35 ARM64 emulator. The app used
`http://10.0.2.2:8001/otlp/release-smoke`, cold-started successfully, remained alive, and exercised
the **Pizza, Please!** action before being backgrounded and foregrounded.

This run used a separate host-side HTTP recorder, not Faro Collector, to isolate the minified OTLP
export path. The recorder verifies request paths and non-empty bodies; it does not decode or validate
the protobuf payloads.

```bash
python3 -u - <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer


class Recorder(BaseHTTPRequestHandler):
    def do_POST(self):
        body = b""
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            while True:
                size = int(self.rfile.readline().split(b";", 1)[0].strip(), 16)
                if size == 0:
                    self.rfile.readline()
                    break
                body += self.rfile.read(size)
                self.rfile.read(2)
        else:
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))

        print(
            f"POST {self.path} bytes={len(body)} "
            f"encoding={self.headers.get('Content-Encoding')} "
            f"transfer={self.headers.get('Transfer-Encoding')}",
            flush=True,
        )
        self.send_response(200)
        self.send_header("Content-Type", "application/x-protobuf")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_):
        pass


HTTPServer(("0.0.0.0", 8001), Recorder).serve_forever()
PY
```

```bash
cd Mobiles/android
./gradlew :app:installRelease
adb logcat -c
adb shell am force-stop com.grafana.quickpizza.android
adb shell am start -W \
  -n com.grafana.quickpizza.android/com.grafana.quickpizza.MainActivity
```

The host recorder received non-empty, gzip-compressed OTLP payloads from the minified build:

```text
POST /otlp/release-smoke/v1/traces bytes=1722 encoding=gzip transfer=chunked
POST /otlp/release-smoke/v1/traces bytes=1729 encoding=gzip transfer=chunked
POST /otlp/release-smoke/v1/logs bytes=845 encoding=gzip transfer=chunked
POST /otlp/release-smoke/v1/logs bytes=1147 encoding=gzip transfer=chunked
```

The release APK inspection resolved the R8 names from the generated mapping instead of hard-coding
one build's obfuscated names:

```bash
APK=app/build/outputs/apk/release/app-release.apk
MAP=app/build/outputs/mapping/release/mapping.txt
INSTRUMENTATION_SERVICE=$(
  sed -n 's/^io\.opentelemetry\.android\.instrumentation\.AndroidInstrumentation -> \(.*\):$/\1/p' "$MAP"
)
OKHTTP_PROVIDER=$(
  sed -n 's/^io\.opentelemetry\.exporter\.sender\.okhttp\.internal\.OkHttpHttpSenderProvider -> \(.*\):$/\1/p' "$MAP"
)

if [ -z "$INSTRUMENTATION_SERVICE" ]; then
  echo "AndroidInstrumentation is missing from the R8 mapping" >&2
  exit 1
fi
if [ -z "$OKHTTP_PROVIDER" ]; then
  echo "OkHttpHttpSenderProvider is missing from the R8 mapping" >&2
  exit 1
fi

unzip -p "$APK" "META-INF/services/$INSTRUMENTATION_SERVICE" | wc -l
HTTP_SENDER_FOUND=false
while IFS= read -r service; do
  if unzip -p "$APK" "$service" | grep -Fxq "$OKHTTP_PROVIDER"; then
    printf '%s -> %s\n' "$service" "$OKHTTP_PROVIDER"
    HTTP_SENDER_FOUND=true
  fi
done < <(zipinfo -1 "$APK" | grep '^META-INF/services/')
if [ "$HTTP_SENDER_FOUND" != true ]; then
  echo "OkHttpHttpSenderProvider is missing from release service descriptors" >&2
  exit 1
fi
```

The first command returned `10`, covering every Android instrumentation provider, including OkHttp.
The second found the R8-rewritten OkHttp OTLP HTTP sender in a service descriptor. The release APK
contains six service descriptors rather than debug's eleven. Four omitted descriptors belong to the
SDK autoconfigure SPI, which the Android agent does not use because it builds exporters
programmatically; the fifth is the unused gRPC sender. Together with the live log and trace requests
above, this shows that the required runtime providers remained reachable after R8 minification.

## Validation status

- [x] The module compiles as an Android AAR and is consumed by the runnable demo app.
- [x] Configuration validation has focused unit coverage.
- [x] Reference Kit defaults, additive resources, metrics policy, and upstream override precedence
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

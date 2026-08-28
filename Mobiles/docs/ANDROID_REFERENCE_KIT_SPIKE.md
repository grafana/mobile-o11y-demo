# Android OTel Reference Kit Spike

**Tracking:** [frontend-o11y-knowledge-workbench#113](https://github.com/grafana/frontend-o11y-knowledge-workbench/issues/113)

**Status:** Experimental local module. It is not published or supported for production use.

## Placement decision

The runnable spike lives in `Mobiles/android/grafana-otel-reference-kit` and is consumed by the
existing QuickPizza Android app. This gives the package a real application and build without
creating an empty repository or treating the demo repository as its permanent home.

If the validation gates pass, the production library should move to a dedicated, public,
Grafana-owned Android runtime repository and publish a versioned AAR from a Grafana Maven
coordinate. Mobile O11y should own releases and the supported `opentelemetry-android` version
window.

The existing repositories are not suitable permanent homes:

| Repository | Decision |
| --- | --- |
| `open-telemetry/opentelemetry-android` | Keep generic SDK and instrumentation work upstream. Grafana endpoints, product defaults, and plugins do not belong there. |
| `grafana/faro-android-gradle-plugin` | Keep build-time symbol upload there. It is a Gradle plugin, not an application runtime library. |
| `grafana/mobile-o11y-demo` | Use it to prove the module against a real app. Do not publish the runtime library from the demo repository. |
| `grafana/frontend-o11y-knowledge-workbench` | Keep strategy and validation records there. It is not a runtime source repository. |

The final repository name, Maven coordinate, and release automation still require team agreement
before the module is extracted or published.

## Package boundary

The spike owns only startup configuration that is specific to the Grafana distribution:

- the OTLP endpoint and headers;
- disk buffering defaults;
- service and additional resource attributes;
- the semantic-convention compatibility choice;
- background-session inactivity and maximum-lifetime defaults.

It delegates initialization and instrumentation discovery to the upstream Android SDK and returns
`OpenTelemetryRum`. It does not define Grafana tracer, logger, span, or meter APIs. The optional
configuration callback exposes the upstream DSL for settings not represented by the Reference Kit.
Its upstream `resource {}` method replaces the full resource action in 1.5.1; additive custom
resource attributes belong in `GrafanaOtelConfiguration.resourceAttributes` instead.

The app still owns application-specific behavior, including its temporary crash-flush workaround,
native crash replay, runtime config UI, and business instrumentation.

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
5. From `Mobiles/android`, run `./gradlew :app:dependencies --write-locks` to regenerate the
   remaining dependency and buildscript locks.
6. Leave application tracer, logger, context propagation, and instrumentation calls unchanged.

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

On August 28, 2026, commit `ba695485c9c9ac7b98df3903054af423c8c5024a` was tested on the
`quickpizza_pixel_35` Android 15 API 35 ARM64 emulator. The local Faro stack used the
`app-o11y-kwl-endpoint` Docker Compose setup, and the QuickPizza backend was built from the same
commit. The app used `http://10.0.2.2:8001/otlp/${APP_KEY}` for Faro OTLP ingest and
`http://10.0.2.2:3333` for the backend.

The relevant setup and run commands were:

```bash
# From app-o11y-kwl-endpoint
docker compose -f docker-compose.yml -f docker-compose.with-plugin.yml up -d

# From the mobile-o11y-demo root
make docker-build
docker run -d --name fokwb-quickpizza-pr110 \
  --network app-o11y-kwl-endpoint_default \
  -p 3333:3333 -p 3334:3334 -p 3335:3335 \
  -e QUICKPIZZA_OTLP_ENDPOINT=http://downstream-otel-collector:4318 \
  -e QUICKPIZZA_TRUST_CLIENT_TRACEID=1 \
  -e QUICKPIZZA_OTEL_SERVICE_NAME=quickpizza \
  -e QUICKPIZZA_OTEL_SERVICE_INSTANCE_ID=pr110-backend \
  -e OTEL_RESOURCE_ATTRIBUTES=deployment.environment=local-pr110,service.version=ba695485 \
  grafana/quickpizza-local:latest

# From Mobiles/android, after configuring config.json with the endpoints above
./gradlew :grafana-otel-reference-kit:testDebugUnitTest \
  :app:assembleDebug :app:installDebug
adb logcat -c
adb shell am force-stop com.grafana.quickpizza.android
adb shell am start -W \
  -n com.grafana.quickpizza.android/com.grafana.quickpizza.MainActivity
```

After the disk buffer flushed, Faro Collector returned `202` for both
`/otlp/${APP_KEY}/v1/logs` and `/otlp/${APP_KEY}/v1/traces`. The translated Loki records contained:

- `session_start`, `rum.sdk.init.*`, `view_changed`, and `app.screen.view` events;
- an `app_startup` measurement with `coldStart=1`;
- `faro.tracing.fetch` for `GET /api/quotes` with HTTP status `200`;
- the same session ID, `0681ff7a3730ee8017c4dfc2de9d715a`, on the startup, screen, and HTTP
  records.

The product-path query used for those checks was:

```bash
curl -fsS -G http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={service_name="QuickPizza_Android_PR110_20260828"}' \
  --data-urlencode 'since=1h' \
  --data-urlencode 'limit=5000' \
  --data-urlencode 'direction=forward' \
  | jq -r '.data.result[].values[][1]' \
  | rg 'event_name=(session_start|app\.screen\.view|view_changed|faro\.tracing\.fetch)|type=app_startup'
```

Tempo trace `96463f9ae47807b4456fd529ebd80c9b` proved the connected HTTP path. The
Android `GET` client span was `b03d415ad8e262b9`; the QuickPizza `GET /api/quotes` server span was
`50238a404dafdd88` and named the Android span as its parent. The backend `SELECT` span then named
the server span as its parent.

```bash
curl -fsS \
  http://localhost:3200/api/traces/96463f9ae47807b4456fd529ebd80c9b \
  | jq -r '
      .batches[]
      | (.resource.attributes
          | map(select(.key == "service.name"))[0].value.stringValue) as $service
      | .scopeSpans[].spans[]
      | [$service, .name, .kind, .spanId, (.parentSpanId // "")]
      | @tsv'
```

Observed output (Tempo represents span IDs as base64 in this response):

```text
QuickPizza_Android_PR110_20260828  GET              SPAN_KIND_CLIENT  sD1BWtjiYrk=
quickpizza                         GET /api/quotes  SPAN_KIND_SERVER  UCOKQE2v3Yg=  sD1BWtjiYrk=
quickpizza                         SELECT           SPAN_KIND_CLIENT  BfrFBqbo/QQ=  UCOKQE2v3Yg=
```

The Faro OTLP endpoint returned `400` for periodic OTLP metrics because that route currently
supports logs and traces only. The required Android Mobile O11y paths above are produced from logs
and traces, so this did not block these runtime gates. A production package still needs an explicit
metrics policy: disable metric export when using Faro OTLP ingest, or route metrics to an endpoint
that supports them.

## Validation status

- [x] The module compiles as an Android AAR and is consumed by the runnable demo app.
- [x] Configuration validation has focused unit coverage.
- [x] Reference Kit defaults and upstream override precedence have focused mapping coverage.
- [x] Kotlin and Java callers have a source-level startup path.
- [x] The package returns upstream OTel runtime and API types.
- [x] Existing application instrumentation compiles without changes.
- [x] The demo cold-starts through the module on API 23 and Android 15 ARM64 emulators.
- [x] Run the app against Faro Collector and verify required Mobile O11y signals.
- [x] Verify a mobile HTTP span remains connected to the QuickPizza backend trace.
- [ ] Automate the add/remove build using a supported non-Grafana provider.
- [ ] Agree on the production repository, Maven coordinate, release owner, and support window.
- [ ] Add binary API compatibility validation before publishing a versioned AAR.
- [ ] Document the final public setup, migration, removal, and limitations after runtime validation.

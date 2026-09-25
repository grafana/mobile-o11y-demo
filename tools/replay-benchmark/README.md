# QuickPizza replay format comparison

This opt-in instrumentation test drives the actual QuickPizza Activity and its existing OTel SDK.
It uses the public replay recorder, the current conservative masking policy and current Faro
transport. The local receiver saves every received checkpoint and acknowledges it after writing.
It is a test sink, not the Grafana collector or proof of backend persistence. Normal pizza APIs
are forwarded to a real local QuickPizza server using the repository's catalog/copy/recommendation
handlers and a test-owned SQLite database.

The capture run collects 300 fresh frames over a five-minute journey: Home, populated synthetic
Login fields, customization, scrolling down and back up, a handled checkout error, landscape,
portrait and another Login/Home visit. The two-minute recorder bound is preserved by restarting
at 100 and 200 seconds. SDK session defaults remain unchanged. The instrumentation explicitly
calls the user-capture API at a one-second target interval; it does not implement production
automatic recording or passive session lookup.

## Run locally

Use JDK 17, Go, Python 3 and an API 30+ Android emulator. Use isolated local ports 18002/18003.
The alternate Android config must point BASE_URL to `http://127.0.0.1:18002`, REPLAY_ENDPOINT to
`http://127.0.0.1:18002/collect/quickpizza-benchmark`, and OTLP_ENDPOINT to
`http://127.0.0.1:18002/otlp/quickpizza-benchmark`. Leave OTLP credentials empty and omit the
shortened session-lifetime setting used by the earlier session-expiry test. Use an absolute
test-owned output directory outside the repository for the following commands.

From the repository root, start these as two separate local processes:

```sh
go build -o /path/to/output/quickpizza-backend tools/replay-benchmark/backend.go
/path/to/output/quickpizza-backend /path/to/output/pizza.db
```

```sh
python3 tools/replay-benchmark/receiver.py /path/to/output/receiver
```

From `Mobiles/android`, build with the alternate config and local replay-library checkout:

```sh
QUICKPIZZA_ANDROID_CONFIG_FILE=/path/to/android-config.json \
  ./gradlew -PfaroReplayDir=/path/to/faro-android-replay \
  :app:assembleDebug :app:assembleDebugAndroidTest
adb reverse tcp:18002 tcp:18002
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb install -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb shell am instrument -w -r \
  -e class com.grafana.quickpizza.features.debug.QuickPizzaFormatComparisonTest \
  -e quickPizzaBenchmark true -e benchmarkSeconds 300 -e benchmarkRun capture-300 \
  com.grafana.quickpizza.android.test/androidx.test.runner.AndroidJUnitRunner
```

Require `OK (1 test)` in the output, not merely adb exit status zero. Every run name must be new;
neither the receiver nor the test overwrites an existing run. A ten-second smoke run compresses
the action schedule and is useful for setup, but is not used for final measurements.

Repeat with `-e benchmarkBaseline true` and a different run name, such as `baseline-300`.
This performs the same actions and profiling with the recorder idle. Compare main-thread CPU,
process CPU and sampled PSS between the two runs. Process CPU includes test code and preparation
of candidate images; the difference is not a pure production-recorder allocation or CPU metric.
One emulator pair is not a physical-device battery, thermal or statistically robust jank study.

Export both directories before Gradle connected-test cleanup can uninstall the app:

```sh
adb exec-out run-as com.grafana.quickpizza.android tar -cf - -C files \
  format-comparison-capture-300 format-comparison-baseline-300 > /path/to/output/quickpizza-runs.tar
```

The replay library's `tools/replay-comparison/analyze.py` and `serve.py` accept the capture directory.
They decode every video frame, verify timestamps/hold durations and provide local playback/seek
checks. Preserve receiver bodies, run summaries and exact APK/source hashes with the results.
Stop the two local servers and the test emulator when finished.

## Candidate formats and limits

The test derives both candidates from the same received, already-masked screenshots. It normalizes
them on Android to an 800-pixel long edge with WebP quality 30. The image candidate models a
32-entry / 8 MiB LRU of confirmed files, scoped to session/recording, screen and dimensions. It
checks exact bytes before reusing a hash match and retains every original capture timestamp.
Files are reused only after a local file write. This model does not replace the current Faro
transport or establish the eventual upload API.

Android MediaCodec encodes groups of up to five frames to H.264 at a requested 75 kbps. Rotation
and recording changes split clips; each clip preserves actual frame timestamps and the final
hold time. `BenchmarkVideoEncoder.kt` comes from the replay library benchmark at `6e8be87`.
Its input is decoded WebP, so PSNR measures additional video loss, not equal perceptual quality.
Encoding happens after capture; its caller CPU excludes codec-service CPU, and the two formats
are not being encoded concurrently with the journey.

The receiver counts actual current Faro HTTP request-body bytes. Candidate media plus compact
playback JSON are separately measured payload sizes. They exclude production API envelopes,
request headers, retries and remote storage costs. Do not report them as observed production
network savings. The local viewer is not the Frontend Observability session panel.

Mask-region interiors are checked on the original received bitmap using the library test's
8-level RGB tolerance for lossy WebP. A sampled gray-pixel fraction records how much of the
captured image is covered. QuickPizza currently exposes only registered static public labels;
that policy removes most motion and texture, which strongly affects this comparison. It does
not validate generic Compose masking or determine the best format for animated apps.

# QuickPizza screenshot smoke (historical)

For the multipart MP4 implementation and automatic demo triggers, use
[Automatic captures](AUTOMATIC_CAPTURE.md). The walkthrough below records the earlier manual
screenshot smoke and its historical test results; its upload format and publication notes do
not describe the current integration branch.

The earlier local smoke below exercises the actual Android app, its existing OTel
session, the replay library, conservative masking and current Faro screenshot requests. It needs
no Grafana credentials or new file-upload API. The receiver is a local test sink; this run does
not prove Grafana storage, the mobile session panel or Narrator links.

The corrected [five-minute format comparison](results/common-source/README.md) is ready to read.
That comparison informed the format discussion. The current integration now uses multipart MP4
uploads; these screenshot instructions and comparison results are retained for reference.

## Get the two codebases

Use this QuickPizza integration checkout and the replay library from
[PR #1](https://github.com/grafana/hackathon-18-faro-android-replay/pull/1). The verified library
revision is `da8ff66c8a2fa220fc8096cc91e8956acd003771` on `varanha/stage3-quickpizza-journey`.
The library has not been published to Maven. The app resolves it with a Gradle composite build.

The QuickPizza integration is shared through
[PR #126](https://github.com/grafana/mobile-o11y-demo/pull/126). Use the screenshot-era app and
library revisions together when reproducing this historical run. For current MP4 setup and
results, follow [Automatic captures](AUTOMATIC_CAPTURE.md); the library PR alone does not contain
the app integration.

## Run the smoke

Requirements: JDK 17, Go 1.25 or newer, Python 3, Android SDK 37, platform-tools, the CMake/NDK
requested by the Android build, and a booted disposable API 30+ emulator. The fresh-source
verification used API 35, CMake 3.22.1 and NDK 28.2.13676358. Leave local ports 18002 and 18003 free.
Use a separate emulator because the test installs QuickPizza and can reset its demo data.

From the QuickPizza repository root, replace the paths and emulator serial:

```sh
export JAVA_HOME=/path/to/jdk-17
export ANDROID_HOME=/path/to/Android/sdk
python3 tools/replay-benchmark/smoke.py /path/to/new-output-directory \
  --library /path/to/faro-android-replay \
  --adb "$ANDROID_HOME/platform-tools/adb" \
  --serial emulator-5554
```

If this disposable emulator already has QuickPizza installed, add `--reset-test-app`. That flag
clears only this emulator's QuickPizza demo data, including saved Debug endpoint overrides.
Do not use it on your usual demo installation. The script refuses physical devices, existing
output directories and an existing reverse mapping on port 18002.

The script generates a local-only Android config, builds the Go backend and debug/test APKs,
runs the app's JVM tests, starts the two local servers, and drives ten captures through Home,
Login with synthetic populated fields, scrolling, a handled error and rotation. It preserves the
SDK's normal session settings. The compressed action schedule can take longer than ten seconds.
It then exports the app evidence, stops the app and its servers, and removes its reverse mapping.
The emulator and installed APKs remain available; shut down your test emulator when finished.

Success requires `OK (1 test)` in `instrumentation.log` and ten received frames in
`smoke-result.json`. Inspect these files in the output directory:

- `build.log`: debug/test builds and JVM tests.
- `receiver/handoff-smoke/frame-*.webp`: actual masked emulator captures.
- `receiver/handoff-smoke/body-*.json`: current Faro request bodies with capture-time identity.
- `app-evidence.tar`: journey, timestamps, samples and local encoder outputs.
- `smoke-result.json`: device/API, screens, received-frame count and APK hashes.

The smoke still runs the original WebP-to-video harness after capture. Its sizes are **not** new
format-comparison results. Use the separate common-source report for that decision.

## Verification

The setup was built from a clean source export with no prior app build output or private Android
config, using library `da8ff66c8a2fa220fc8096cc91e8956acd003771`. Debug and instrumentation APKs
built, all 29 app JVM tests passed, and the selected API 35 emulator journey passed with ten
received masked frames across Login, Home and both orientations. The final launcher was run
again after its cleanup changes; both runs passed. Six Python tests passed, including cleanup
when adb disconnects or a local server does not stop. Python and viewer JavaScript syntax passed.
The owned servers, reverse mapping and emulator were stopped after verification.

A separate `:app:lintDebug` run at that historical revision reported six `NewApi` errors in
`NativeExitCrashReporter.kt` (lines 138–143 and 181), plus 41 warnings and two hints. The smoke
script deliberately runs build, unit tests and its selected device test; it does not claim a
passing full-app lint result at that revision. The current app branch fixes those API annotations
and passes lint with no errors. No suppression or baseline was added. The fair comparison report
retains its original source hashes and results; it was not rerun for this handoff.

## Original integration sequence (completed locally)

The standalone smoke was followed by the multipart MP4 API integration, automatic state
capture, and real storage/readback and Grafana playback checks. The current walkthrough records
the verified results and the remaining CI dependency-access requirement. Session/lifecycle
failure paths are covered by the library suite; the automatic emulator journey also covers
rotation, background/resume and Stop. Narrator links and cloud deployment are not claimed.

`ReplayJourneyTest` is a separate test requiring the real collector proxy's `/_test/receipts`,
OTLP receipt tracking and shortened test-session lifetime. This mock receiver cannot run that
suite. The library's `docs/quickpizza-integration.md` records that earlier local integration and
its limitations. Do not infer new-API readiness from the mock smoke.

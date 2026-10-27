# Shared mobile E2E tests (Arbigent)

One runner and one set of scenario templates drive all four QuickPizza mobile
apps. [Arbigent](https://github.com/takahirom/arbigent) uses an OpenAI model to
operate the app through the platform's accessibility tree. The basic flow opens
the app, requests a pizza recommendation, rates it, backgrounds the app and
brings it back.

## Prerequisites

- `OPENAI_API_KEY` exported.
- `unzip`, `wget` or `curl`, Node.js 24.5+, npm 11.10+.
- QuickPizza backend answering `http://localhost:3333/ready` (see
  [Mobiles/README.md](../README.md)). `QUICKPIZZA_BACKEND_URL` changes only this
  probe, not the app's backend address.
- **Android:** `adb`, an emulator booted, and the app under test installed.
- **iOS (macOS only):** Xcode (`xcrun`), a booted simulator, and the app
  installed. `bash Mobiles/ios/Scripts/sim-run.sh` builds, boots and installs the
  native app; `Mobiles/scripts/open-simulator.sh <udid>` boots a simulator.

The runner does not boot devices or install apps. It fails fast if the
emulator, simulator or installed app is missing.

## Run

From the repository root:

```bash
export OPENAI_API_KEY='sk-...'
./Mobiles/e2e/run_e2e_tests.sh --app=flutter --platform=android
```

| `--app` | Android | iOS |
| --- | :---: | :---: |
| `flutter` | yes | yes |
| `react-native` | yes | yes |
| `android-native` | yes | no |
| `ios-native` | no | yes |

`--flow=basic` is the default. `--flow=handled-exception` triggers a handled
exception from the Debug tab; `--flow=diagnostics` does that and then crashes
the app on purpose and relaunches it. A failed run is retried up to 3 times with
a 45 s pause, so failures take a while.

### React Native on Android

A debug APK installed with `yarn android` has no embedded JS bundle and needs
Metro:

```bash
# Separate terminal, leave running
cd Mobiles/react-native && yarn start

adb reverse tcp:8081 tcp:8081
```

CI builds an offline bundle into the APK instead, so it needs no Metro.

## Results

Results land in `Mobiles/e2e/results/<app>/` (`<app>-handled-exception/` or
`<app>-diagnostics/` for the other flows). Every run is archived; open the
highest-numbered report:

```text
Mobiles/e2e/results/<app>/arbigent-result/arbigent-result-<N>/visual_report.html
```

Results are not split by platform: copy them before switching between Android
and iOS if you want to keep both. `arbigent-cache/` holds Arbigent's AI response
cache and is reused across runs. The rendered `arbigent-project.yaml` is kept at
the result root and in each run, so you can see exactly what Arbigent was asked.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `OPENAI_API_KEY` | _(required)_ | Passed to Arbigent. |
| `ARBIGENT_VERSION` | `0.76.1` | Arbigent CLI release to download. |
| `ARBIGENT_MODEL` | `gpt-5.6-luna` | OpenAI model. |
| `ARBIGENT_LOG_AI_API` | `false` | `true` logs AI request/response payloads. |
| `QUICKPIZZA_BACKEND_URL` | `http://localhost:3333` | Backend readiness probe. |

The templates use OpenAI's Responses API with low reasoning effort, which Luna
needs to call Arbigent's function tools.

## Scenario templates

There are six templates, one per flow and platform:
`arbigent-e2e_<flow>.<android|ios>.yaml.template`, where `<flow>` is
`basic_pizza_flow`, `handled_exception` or `diagnostics`. `render-template.js`
substitutes these tokens before the run:

| Token | Replaced with |
| --- | --- |
| `__ANDROID_PACKAGE__` | Android package id of the app under test. |
| `__IOS_BUNDLE_ID__` | iOS bundle id of the app under test. |
| `__RECOVERY_BLOCK__` | [`arbigent-recovery-hints.txt`](./arbigent-recovery-hints.txt), indented and appended to the end of each goal. |

The recovery hints are generic "if stuck" guidance (dismiss modals, scroll, wait
once) shared by all flows. The HTML report is built by `report-generator/`.

## CI

| Workflow | Trigger | Vault | Purpose |
| --- | --- | --- | --- |
| [`mobile_demo_telemetry_build.yaml`](../../.github/workflows/mobile_demo_telemetry_build.yaml) | `pull_request` | No | Build checks, forwarding and version-script tests |
| [`mobile_demo_telemetry.yaml`](../../.github/workflows/mobile_demo_telemetry.yaml) | every 2 h, `workflow_dispatch`, path-filtered push to `main` | Yes | Build, e2e and dual-stack Grafana Cloud telemetry |

The full workflow runs two legs in parallel. The Android leg (`ubuntu-latest`)
starts the backend with Docker Compose, builds the Flutter, React Native and
native Android APKs and runs each on one emulator. The iOS leg (`macos-26`)
runs the backend natively and does the same for the three iOS apps on one
simulator. Builds are not uploaded; only e2e results (1-day retention) and logs
are. Secrets: [telemetry/README.md](../telemetry/README.md#github-actions).

A green run confirms the UI flow, not telemetry delivery. Check the target
stacks for the data.

To run the full workflow on a feature branch, dispatch it from Actions. The
branch must be allowed by the `mobile-demo-telemetry` environment's branch
policy to get secrets.

Scheduled runs also emit diagnostic data, bucketed on UTC wall-clock time:

- handled-exception flow about every 6 h;
- crash diagnostics about every 20 h, which replaces the handled-exception
  flow on that run (the crash flow emits one handled exception first);
- `workflow_dispatch` runs the basic flow only, unless `run_diagnostics=true`
  forces crash diagnostics.

### Demo app version variation

CI varies app versions so Mobile O11y shows a small version distribution
instead of one flat version. Flutter resolves the version at runtime when
`CI_DEMO_VERSIONING=true`. React Native resolves the Faro-reported version at
bundle time. Native Android and iOS resolve it during the CI build and bake it
into `versionName` / `MARKETING_VERSION`, so installed app metadata and
telemetry agree for that run.

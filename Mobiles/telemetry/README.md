# Send telemetry to two stacks

Local apps export directly to their configured endpoint by default. Optional
dual-stack setup forwards telemetry to two stacks through Alloy (native/backend
OTLP) and nginx (Flutter/RN). Each app uses one local endpoint through generated
build configuration; saved app settings are preserved.

See [prerequisites](DETAILS.md#setup) before running setup.

## Guided setup

From the repository root:

```sh
python3 Mobiles/telemetry/setup.py
```

Setup reuses your saved destinations (or asks for them once), installs missing
forwarding tools, starts one QuickPizza backend, and activates build configs for
**all four apps on both iOS and Android**. There is no platform selection.
The services stay running until teardown; you launch the apps yourself.

Setup requires a running Docker engine and starts the microservices backend on
port `3333`. If Docker is unavailable or unresponsive, setup exits with guidance
to start or restart it. Generated app configs select the correct host address
for each simulator/emulator.

Then build/run:

| App | After setup |
| --- | --- |
| Flutter in Cursor / VS Code | Open the repo root, choose **Flutter (debug)**, select your device, press **F5**. The launch task selects the active config automatically. |
| Flutter from terminal | Run `Mobiles/flutter/scripts/run-ios.sh` or `run-android.sh`. Both select the active config automatically. |
| React Native | Restart Metro with `--reset-cache`, then rebuild/run on either platform. One Metro instance can serve both platforms. |
| Native Android | Sync Gradle in Android Studio, then rebuild/run. |
| Native iOS | Rebuild/run in Xcode. |

You can run several apps against the same setup. Build the two Flutter platforms
sequentially in one checkout. Saved in-app endpoint overrides still take
precedence: clear those overrides in Debug → Config if an app uses an old URL.

## Backend options and automation

```sh
# Docker microservices (the default).
python3 Mobiles/telemetry/setup.py --backend docker

# Forwarding only, when you manage the backend yourself.
python3 Mobiles/telemetry/setup.py --backend none

# No prompts; use a private destination file.
python3 Mobiles/telemetry/setup.py --non-interactive \
  --destinations /path/to/destinations.json
```

Docker collects backend OTLP, container logs, scraped metrics and profiles.
Setup uses the mobile QuickPizza image; set `QUICKPIZZA_IMAGE` explicitly to
use your own build. `--backend none` skips the Docker check and preserves the
backend addresses from your saved app configs.

JSON can also be supplied in `MOBILE_TELEMETRY_DESTINATIONS` or with
`--destinations -` on stdin. Append `-- COMMAND ARG…` to wrap a complete test run
with automatic teardown. Existing `--docker-backend` remains an alias for
`--backend docker`; `--platform` only selects the legacy single-platform field
for external consumers, not which apps setup enables.

## GitHub Actions

Manual, scheduled and main-branch telemetry runs always use both stacks.
PR forwarding tests use local recorders, no secrets.

Create **one Vault secret** for dual-stack runs:

- Path: `ci/repo/grafana/mobile-o11y-demo/mobile_telemetry_destinations`
- Field: `value`
- Value: the complete private destination JSON used locally, including both
  `cloud` objects. Use actual values, not unresolved `${ENV_VAR}` placeholders.

[JSON fields and where to get each value](DETAILS.md#destination-json) ·
[Update endpoints or rotate tokens](DETAILS.md#update-an-endpoint-or-rotate-a-token)

The test runner also requires the Vault secret `openai_api_key`, field `value`.
After configuring destinations, dispatch the workflow manually and check both
Android and iOS jobs before relying on the two-hour schedule.

## Teardown

Stop apps after their SDKs flush, then:

```sh
python3 Mobiles/telemetry/teardown.py
```

Forwarding drains/stops; the managed Docker backend stops too. Saved
credentials and Docker volumes remain. **Rebuild/reinstall apps** to restore
original endpoints; restart Metro and sync native Android. Flutter’s next Cursor
launch or helper-script run selects the ordinary `config.json` automatically. Restart the backend using your usual Compose
command. Already-installed apps do not switch endpoints automatically.

One active setup per checkout; emulator/simulator only. Docker setup manages the
demo Compose project. Faro secondary delivery is best-effort. Private
logs in `.runtime/local/` can contain credentials.

[Configuration, prerequisites and troubleshooting](DETAILS.md)

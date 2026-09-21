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

Choose a simulator platform, whether to manage the Docker backend, and enter
both stacks’ destinations. Setup saves credentials privately, installs missing
forwarding tools, and starts them. Later runs reuse the saved destinations.

Then build/run:

| App | After setup |
| --- | --- |
| Android Studio | Sync Gradle, rebuild/run |
| Xcode | Rebuild/run |
| React Native | Restart Metro with `--reset-cache`, rebuild/run |
| Flutter | From `Mobiles/flutter`: `flutter run --dart-define-from-file=../telemetry/.runtime/local/flutter.json` |

## CI / agents

Fill in a private copy of [destinations.example.json](destinations.example.json)
using the [field guide](DETAILS.md#destination-json).
Pass its path; `--docker-backend` is optional.

```sh
python3 Mobiles/telemetry/setup.py --non-interactive --platform android \
  --destinations /path/to/destinations.json --docker-backend
```

Alternatively, supply JSON in `MOBILE_TELEMETRY_DESTINATIONS` or with
`--destinations -` on stdin. Append `-- COMMAND ARG…` to wrap a complete test run
with automatic teardown.

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

Forwarding drains/stops; any Docker backend managed by setup stops too. Saved
credentials and Docker volumes remain. **Sync/rebuild/reinstall apps** to restore
original endpoints; restart Metro. Restart the backend using your usual Compose
command. Already-installed apps do not switch endpoints automatically.

One active setup per checkout; emulator/simulator only. Docker setup manages the
demo Compose project. Faro secondary delivery is best-effort. Private
logs in `.runtime/local/` can contain credentials.

[Configuration, prerequisites and troubleshooting](DETAILS.md)

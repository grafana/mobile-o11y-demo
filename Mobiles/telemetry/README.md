# Send telemetry to two stacks

By default each app exports straight to its configured endpoint. Dual-stack
setup instead points every app at a local forwarder, which copies telemetry to
two Grafana Cloud stacks: Alloy for native and backend OTLP, nginx for Flutter
and React Native Faro payloads. Saved app settings are preserved.

Prerequisites: Python 3.10+, a C compiler, OpenSSL and PCRE2 headers, and a
running Docker engine (unless you use `--backend none`).

- macOS: `brew install openssl@3 pcre2`
- Debian/Ubuntu: `sudo apt-get install build-essential libssl-dev libpcre2-dev unzip`

## Setup

From the repository root:

```bash
python3 Mobiles/telemetry/setup.py
```

Setup reuses your saved destinations (or asks for them once), installs the
forwarding tools if missing, starts one QuickPizza backend on port `3333`, and
activates build configs for all four apps on both iOS and Android. Services run
until teardown; you launch the apps yourself.

The backend image `quickpizza-mobile-local:development` is built from this
checkout on every start (Docker reuses cached layers). Export `QUICKPIZZA_IMAGE`
to use an existing image instead. If you already run the standalone backend,
stop it first with `docker stop quickpizza`: both use port `3333`.

Then build and run the apps:

| App | After setup |
| --- | --- |
| Flutter in Cursor / VS Code | Open the repo root, choose **Flutter (debug)**, select your device, press **F5**. The active config is picked automatically. |
| Flutter from terminal | `Mobiles/flutter/scripts/run-ios.sh` or `run-android.sh`; both pick the active config. |
| React Native | Restart Metro with `--reset-cache`, then rebuild/run. One Metro serves both platforms. |
| Native Android | Sync Gradle in Android Studio, then rebuild/run. |
| Native iOS | Rebuild/run in Xcode. |

Several apps can run against one setup; build the two Flutter platforms one
after the other. One active setup per checkout. Emulators and simulators only.

## Options

```bash
# Forwarding only, when you manage the backend yourself.
python3 Mobiles/telemetry/setup.py --backend none

# No prompts; use a private destination file (or - for stdin).
python3 Mobiles/telemetry/setup.py --non-interactive \
  --destinations /path/to/destinations.json
```

`--backend none` keeps the backend addresses in your saved app configs and does
not redirect your backend's telemetry; see [Backend scope](DETAILS.md#backend-scope).
Destination JSON can also come from `MOBILE_TELEMETRY_DESTINATIONS`. Append
`-- COMMAND ARG...` to wrap a run with automatic teardown.

## GitHub Actions

Manual, scheduled and `main` telemetry runs always use both stacks. PR
forwarding tests use local recorders and need no secrets. The workflow needs two
Vault secrets, both read from field `value`:

- `ci/repo/grafana/mobile-o11y-demo/mobile_telemetry_destinations`: the whole
  destination JSON as one string, including both `cloud` objects, with literal
  values (no `${ENV_VAR}` placeholders).
- `openai_api_key`: the OpenAI key for the [e2e runner](../e2e/README.md).

[JSON fields](DETAILS.md#destination-json) ·
[Update endpoints or rotate tokens](DETAILS.md#update-an-endpoint-or-rotate-a-token)

## Teardown

Let apps flush their SDKs, stop them, then:

```bash
python3 Mobiles/telemetry/teardown.py
```

Forwarding drains and stops, and so does the managed backend. Saved destinations
and Docker volumes are kept. Installed apps keep the endpoint they were built
with: rebuild/reinstall them (restart Metro, sync native Android) to return to
direct export. See [Troubleshooting](DETAILS.md#troubleshooting).

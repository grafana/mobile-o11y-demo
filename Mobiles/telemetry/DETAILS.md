# Configuration and troubleshooting

Start with the [quick guide](README.md). This page covers destination values,
updates and the lower-level tools.

## What gets duplicated

Each app uses one endpoint and ordinary SDK setup. Forwarding owns the Cloud
credentials and copies telemetry to the two destinations.

| Input | Forwarding | Destination in each stack |
| --- | --- | --- |
| Native iOS/Android traces and logs | Separate Alloy OTLP listeners | That native app's registration |
| Flutter/RN Faro payloads | nginx mirroring, unchanged body | That Faro app's registration |
| Backend OTLP traces, logs and metrics | Alloy | Backend OTLP gateway |
| Docker scrape metrics, container logs and pprof profiles | Docker Alloy pipeline | Metrics, logs and profiles receivers |

The primary Faro destination controls SDK responses, including sampling and
`Retry-After`. Secondary Faro delivery is best-effort, with no retry queue.
Align sampling policies when comparing stacks. OTLP uses separate in-memory
queues and bounded retries; long outages or shutdown can still lose data.

nginx preserves Faro's session/device/view envelope. Alloy 1.19.2's Faro round
trip loses some of that metadata, so this profile does not use it for Faro.

## Setup

Requires Python 3.10+, a C compiler, OpenSSL and PCRE2 headers:

- macOS: `brew install openssl@3 pcre2`
- Debian/Ubuntu: `sudo apt-get install build-essential libssl-dev libpcre2-dev unzip`

`setup.py` installs private, checksum-verified Alloy 1.19.2 and nginx 1.30.5
binaries when missing. Docker is required only for `--docker-backend`; app builds
still need their usual toolchains. Nothing is installed as a system service.

## Destination JSON

The same JSON works locally and as Vault's `mobile_telemetry_destinations` value.
Guided setup creates the ignored `Mobiles/telemetry/destinations.local.json`.
For manual configuration, copy [destinations.example.json](destinations.example.json)
to that path and replace every `${…}` placeholder with an actual value.

There are two complete objects: `primary` (the preferred destination) and
`secondary` (the additional destination). Fill these fields **for each stack**:

| JSON field | Where to get it / format |
| --- | --- |
| `flutter` | Collector URL from the Flutter app's Mobile Observability setup page. |
| `react-native` | Collector URL from the React Native app's setup page. |
| `ios.endpoint` | App-specific OTLP base URL from the native iOS app's setup page. |
| `android.endpoint` | App-specific OTLP base URL from the native Android app's setup page. |
| `ios.headers`, `android.headers` | Keep `{}` for these app URLs; their path contains the app key. |
| `backend.endpoint` | Stack's OpenTelemetry setup: OTLP HTTP base URL, ending in `/otlp`. |
| `backend.headers.Authorization` | Full header: `Basic ` followed by Base64 of `OTLP_USERNAME:TOKEN`. Get the username from OpenTelemetry setup; guided setup computes this header. |
| `cloud.stack` | Stack slug from the Cloud portal, not its URL or numeric ID. |
| `cloud.token` | Cloud Access Policy token for this stack; use the same token as backend authorization. |
| `cloud.api_url` | Cloud stack API base URL, normally `https://grafana.com/api/instances/`. Match the stack’s environment and keep the trailing slash. |

Use a stack-scoped Cloud Access Policy token with `metrics:write`, `logs:write`,
`traces:write`, `profiles:write` and `stacks:read`. A Grafana login/service-account
token is a different credential. Both `cloud` objects are required for CI's
Docker collection; native-only local runs can omit them.

Keep native app URLs separate from the backend gateway. OTLP base URLs must not
include `/v1/traces`, `/v1/logs` or `/v1/metrics`. Use the advertised backend URL;
do not derive it from the stack's Grafana hostname or `clusterSlug`.

Local JSON also supports `${ENV_VAR}` references, with no shell evaluation.
For Vault, use literal values so no additional destination secrets are needed.
Store the **whole JSON object as the string value of the `value` field**, not
separate Vault fields for `primary` and `secondary`. Exact Vault path and workflow
selection: [GitHub Actions setup](README.md#github-actions).

## Update an endpoint or rotate a token

1. Edit the saved private JSON. Endpoint change: update only that app/stack's
   field. Token rotation: update **both** `cloud.token` and
   `backend.headers.Authorization` for that stack; recompute the Basic header
   with the new token and the stack's OTLP username.
2. Run teardown, then setup with that file using the [quick-guide commands](README.md).
   Setup reuses saved values; it does not prompt to replace an existing file.
   Exercise an app and confirm the same session/trace in both stacks. Readiness
   alone only proves the local listeners started.
3. Replace Vault's entire `value` with the updated JSON. Dispatch the telemetry
   workflow manually; check both Android and iOS jobs
   and Cloud delivery. Revoke the old token after verification.

Running forwarders keep their loaded configuration: restart them after updating
local values. CI loads Vault afresh on each run. Changing Cloud destinations
alone needs no app rebuild if the local listener addresses stay the same.
Never commit the JSON or upload generated configs/logs as artifacts.

## Backend scope

`setup.py --docker-backend` manages the demo microservices Compose project
and ports. Teardown stops that backend and retains volumes. It is not a second,
isolated Compose project. Docker Alloy uses `backend_pipeline.alloy` for
discovery and resource transforms.

For a native backend, source `.runtime/local/env.sh` before starting it, and keep
`QUICKPIZZA_TRUST_CLIENT_TRACEID=1`. This supplies `QUICKPIZZA_OTLP_ENDPOINT` and
preserves mobile/backend trace relationships. Native runs, including macOS CI,
duplicate OTLP only; they do not add scraping, process logs or profiling.

PostgreSQL database-observability collectors are outside this profile. Source-map
and native-symbol uploads are separate: upload to both app registrations if both
stacks need symbolication.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Setup fails | Missing tools, occupied ports or incomplete destination JSON. Private logs are in `.runtime/local/`; they can contain credentials. |
| App still sends directly | Sync/rebuild/reinstall; restart Metro with `--reset-cache`. Clear saved in-app endpoint overrides. Flutter needs the generated `--dart-define-from-file`. |
| Setup says already active | Run teardown before another setup. Retry teardown after a partial failure; saved destinations remain. |
| Ready, but Cloud data missing | App key, token scopes, TLS/CA and sampling. Inspect both stacks; a successful primary response does not prove secondary delivery. |
| Returning to direct export | Teardown, rebuild/reinstall and restart Metro. Unset any explicit `QUICKPIZZA_*_CONFIG_FILE` variables. Installed apps retain their built endpoint. |
| Destination DNS changed | Restart forwarding; nginx resolves upstream names at startup. |

Leave apps alive for their SDK export interval before stopping them; CI allows
30 seconds. Stop backend producers before forwarding. Teardown finishes in-flight
Faro requests and gives OTLP queues a bounded drain window (30 seconds by default),
then gracefully stops processes. Empty queues do not prove Cloud acceptance.
SIGINT/SIGTERM clean up owned processes; SIGKILL or a host crash cannot.

## Maintainer tools

Normal use needs only setup/teardown. CI uses `ci.py`, `backend-compose.sh` and
`telemetry.py` directly. The supervisor supports `run`, detached `start`, `status`
and `stop`; use the same `--run-dir` throughout. `run … -- COMMAND ARG…` wraps a
command and cleans up afterward. Profile `default` starts no forwarders.

```sh
python3 Mobiles/telemetry/telemetry.py run --profile dual-stack \
  --destinations Mobiles/telemetry/destinations.local.json --platform android
# In the build/backend terminal:
source Mobiles/telemetry/.runtime/run/env.sh
```

This lower-level command exports build selectors through `env.sh`; it does not
activate the IDE configuration symlink used by setup. Native iOS direct builds
can pass `-xcconfig "$QUICKPIZZA_IOS_CONFIG_FILE"`; initialize a fresh checkout
with `SRCROOT="$PWD" Scripts/generate-config.sh` from `Mobiles/ios`.

Listeners bind to loopback: iOS `17118`, Android `17120`, backend `17119`, Faro
`17134`, Alloy health `17123`. Android uses `10.0.2.2`; iOS uses `127.0.0.1`.
Concurrent lower-level sessions need separate run directories and `--port-offset`
values; parallel app builds also need separate build directories/worktrees.
Physical devices are outside this profile.

Use `ALLOY_BIN`/`NGINX_BIN` for existing tools, `--skip-install` on setup to disable
installation, or the supervisor's `--ca-file` for a missing host CA bundle.

```sh
python3 -m venv Mobiles/telemetry/.runtime/test-venv
Mobiles/telemetry/.runtime/test-venv/bin/pip install -r Mobiles/telemetry/tests/requirements.txt
ALLOY_BIN="$PWD/Mobiles/telemetry/.runtime/tools/alloy" \
NGINX_BIN="$PWD/Mobiles/telemetry/.runtime/tools/nginx" \
Mobiles/telemetry/.runtime/test-venv/bin/python -m unittest discover -s Mobiles/telemetry/tests -v
```

The suite tests configuration, real forwarding, retries and lifecycle against
local recorders. Cloud acceptance requires running the apps and checking
sessions and linked backend traces in both stacks.

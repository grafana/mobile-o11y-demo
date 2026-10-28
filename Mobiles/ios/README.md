# QuickPizza iOS Demo App

A native SwiftUI app that sends OpenTelemetry traces and logs over OTLP/HTTP to the Faro
collector. Frontend Observability, Tempo and Loki show them under the name registered for the
app key in the endpoint (`QuickPizza_iOS` on the demo stack).

## Prerequisites

- macOS with Xcode 26+ and an iOS 26+ simulator runtime (the app targets iOS 26.0; the package
  needs Swift tools 6.2, also Xcode 26)
- Python 3 (`Scripts/sim-run.sh` uses it to pick a simulator)
- Docker, for the backend

No CocoaPods or Homebrew. Xcode resolves the Swift packages.

## Run it

### 1. Start the backend

From the repository root:

```bash
docker build -t quickpizza-mobile-local:development .
docker run --rm -d --name quickpizza -p 3333:3333 quickpizza-mobile-local:development
curl http://localhost:3333/api/quotes   # should return JSON
```

### 2. Create your config

```bash
cd Mobiles/ios
cp Config.xcconfig.example Config.xcconfig
```

The defaults work for a simulator with a local backend:

```
BASE_URL = http:/$()/localhost:3333
PORT = 3333
OTLP_ENDPOINT =
OTLP_INSTANCE_ID =
OTLP_API_KEY =
```

- `/$()/` escapes `://` in xcconfig files. Leave it in.
- Keep the `KEY = value` spacing. `Scripts/generate-config.sh` only reads lines in that form.
- On a physical device, `localhost` is the phone. Use `BASE_URL = http:/$()/<your-mac-ip>:3333`
  (ATS does not apply to IP addresses) and allow the Local Network prompt on first launch, or use
  an HTTPS tunnel such as ngrok (see [BrowserStack](#real-device-on-browserstack-optional)).
  The project is signed with Grafana's development team; for your own iPhone, pick your team (and,
  if needed, a unique bundle id) in Xcode under **QuickPizzaIos → Signing & Capabilities**.
- An empty `OTLP_ENDPOINT` means OpenTelemetry is not started at all. The app still runs and
  logs to OSLog only.

### 3. Build and launch on a simulator

```bash
bash Scripts/sim-run.sh                            # booted iPhone simulator, else the newest one
bash Scripts/sim-run.sh --device "iPhone 17 Pro"   # a specific simulator
bash Scripts/sim-run.sh --no-logs                  # exit after launch instead of streaming logs
```

The script builds, installs, launches and then streams the app's logs. Sign in with
`default` / `12345678` and tap **Pizza, Please!**.

Prefer Xcode? Run `open Mobiles/ios/QuickPizzaIos.xcodeproj` from the repository root, pick a
simulator and press **Cmd+R**. The build reads `Config.xcconfig` the same way.

## Send telemetry to Grafana Cloud

1. In Grafana Cloud, open **Frontend Observability**, open your app (or create one), and copy
   its collector URL: `https://faro-collector-<region>.grafana.net/collect/<appKey>`.
2. Change `/collect/` to `/otlp/` and put it in `Config.xcconfig`. Leave both credentials empty;
   the app key in the path identifies the app.

   ```
   OTLP_ENDPOINT = https:/$()/faro-collector-<region>.grafana.net/otlp/<appKey>
   OTLP_INSTANCE_ID =
   OTLP_API_KEY =
   ```

3. Run `bash Scripts/sim-run.sh` again.
4. Look under the app in **Frontend Observability**. Disk buffering delays export, so allow
   tens of seconds.

Endpoint rules:

- Use the OTLP **base** URL. The app appends `/v1/traces` and `/v1/logs`. A trailing slash is fine.
  A URL ending in `/v1/traces`, `/v1/logs` or `/v1/metrics` is rejected and OTel does not start.
- No query string or fragment.

More detail on finding the URL: [Connect to Grafana Cloud](../docs/CONNECT_GRAFANA_CLOUD.md).

**Legacy: Grafana Cloud OTLP gateway.** Set `OTLP_ENDPOINT` to
`https:/$()/otlp-gateway-<regionSlug>.grafana.net/otlp` and fill in both `OTLP_INSTANCE_ID` and
`OTLP_API_KEY`. The app sends them as Basic auth. The data stays raw OTel in Tempo and Loki and does
**not** appear in Frontend Observability. See
[Connect to Grafana Cloud](../docs/CONNECT_GRAFANA_CLOUD.md#alternative-the-otlp-gateway).

## Where config comes from

Highest precedence first:

1. **Debug → Config** in the app. Saved to `UserDefaults`, applied on the **next launch**, and
   wins over everything below. Clear the override if your xcconfig edits seem ignored.
2. The generated `ios.xcconfig` from [`Mobiles/telemetry`](../telemetry/README.md). While
   `setup.py` is active, `Build.xcconfig` includes it and it sets `QUICKPIZZA_IOS_CONFIG_FILE`, so
   every build (Xcode or `sim-run.sh`) reads it instead of `Config.xcconfig`, pointed at the local
   collector. Edits to `Config.xcconfig` have no effect until you run teardown.
3. `Config.xcconfig`.
4. `Config.xcconfig.example`, if `Config.xcconfig` does not exist.

Build-time values go through `Scripts/generate-config.sh` into
`QuickPizzaIos/Core/Config/BuildConfig.generated.swift` (gitignored, do not edit).

## What the app emits

Manual spans (`auth.login`, `pizza.get_recommendation`, `pizza.rate`), automatic `URLSession`
HTTP spans, session events, app and exception logs, screen views, and MetricKit diagnostics.
Startup goes through the local [`grafana-opentelemetry-ios`](grafana-opentelemetry-ios/README.md)
package. The in-app **Debug** tab injects backend errors and latency, sends test logs and
exceptions, and triggers crashes.

Details: [iOS instrumentation guide](../docs/IOS_OBSERVABILITY_OTEL_GUIDE.md).

**Symbols:** there is no dSYM upload. `faro-cli` uploads only JavaScript source maps and Android
symbols, so MetricKit crash and hang stack traces arrive unsymbolicated. Release builds produce a
dSYM (`dwarf-with-dsym`) if you need to symbolicate frames by hand, for example with `atos`.

## Real device on BrowserStack (optional)

BrowserStack re-signs uploads, so build an unsigned IPA:

```bash
cd Mobiles/ios
xcodebuild -project QuickPizzaIos.xcodeproj -scheme QuickPizzaIos \
  -configuration Release -destination "generic/platform=iOS" \
  -archivePath build/QuickPizzaIos.xcarchive \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO archive

mkdir -p build/ipa/Payload
cp -R build/QuickPizzaIos.xcarchive/Products/Applications/QuickPizzaIos.app build/ipa/Payload/
(cd build/ipa && zip -r ../QuickPizzaIos.ipa Payload)

curl -u "<browserstack_user>:<browserstack_key>" \
  -X POST "https://api-cloud.browserstack.com/app-live/upload" \
  -F "file=@build/QuickPizzaIos.ipa"
```

The response has an `app_url` (`bs://...`) to open in App Live.

A real device cannot reach your Mac's `localhost`. Before building, set `BASE_URL` to a hosted
QuickPizza backend, or expose yours with `ngrok http 3333` and use the `https` URL it prints
(`BASE_URL = https:/$()/<id>.ngrok.io`).

## E2E tests

With the app installed on a booted simulator (`bash Scripts/sim-run.sh`), from the repository root:

```bash
export OPENAI_API_KEY='sk-...'
./Mobiles/e2e/run_e2e_tests.sh --app=ios-native --platform=ios
```

Results land in `Mobiles/e2e/results/ios-native/`. See the [mobile E2E README](../e2e/README.md).

## Troubleshooting

**`xcodebuild` not found or license errors**

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
```

**No simulator found.** Download an iOS 26+ runtime in Xcode → Settings → Components, then check
with `xcrun simctl list devices available`.

**Network error in the app.** Check the backend: `docker ps` and
`curl http://localhost:3333/api/quotes`.

**No data in Grafana.**

- Watch the `sim-run.sh` log stream. `OTel not initialized: <reason>` means the endpoint was empty
  or rejected. `OTel SDK: <message>` reports export failures such as a 404 or 401.
- A wrong ingest URL does not fail the app or the e2e run. Only those log lines show it.
- Check the endpoint rules above, and that a Debug → Config override or an active
  `Mobiles/telemetry` setup is not replacing your `Config.xcconfig`.
- For the legacy gateway, check `OTLP_INSTANCE_ID` and `OTLP_API_KEY`. Faro ingest needs neither.

## Further reading

- [iOS instrumentation guide](../docs/IOS_OBSERVABILITY_OTEL_GUIDE.md): what the app emits and how to reuse it
- [`grafana-opentelemetry-ios` package](grafana-opentelemetry-ios/README.md): the startup package reference
- [iOS app architecture](../docs/IOS_APP_ARCHITECTURE.md): code conventions
- [Mobile observability overview](../docs/MOBILE_OBSERVABILITY_OVERVIEW.md): all four apps side by side
- [All mobile apps](../README.md)

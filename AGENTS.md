# AGENTS.md

## Cursor Cloud specific instructions

### Overview

QuickPizza is a Go backend + SvelteKit frontend demo app. No external services are required — it uses in-memory SQLite by default and all microservices run in a single process.

### Running the dev environment

- **Dev mode (live-reload):** `make dev` — starts Vite dev server on `:5173` and Go backend on `:3333` (backend proxies frontend assets from Vite).
- **Production build:** `make build` then `./bin/quickpizza` — embeds built frontend into the Go binary and serves on `:3333`.
- Standard commands are documented in `docs/development.md` and the `Makefile`.

### Lint / format

- **Frontend:** `cd pkg/web && npm run biome-check` (lint) / `npm run biome-format` (auto-fix).
- **Go:** `make format-check` (requires `goimports` on `PATH`; installed to `$(go env GOPATH)/bin`).

### Gotchas

- `goimports` is not a system package — install with `go install golang.org/x/tools/cmd/goimports@latest`. Ensure `$(go env GOPATH)/bin` is on `PATH` (added to `~/.bashrc`).
- The Go backend uses vendored dependencies (`vendor/`), so `go build` works offline without `go mod download`.
- The frontend has no automated test suite — validation is via `biome-check` and `svelte-check` (`npm run check`).
- `make dev` uses `trap 'kill 0' EXIT` — when terminated, it kills both the Vite and Go processes together.
- Authentication for API calls: create a user via `POST /api/users`, log in via `POST /api/users/token/login` to get a bearer token, then pass `Authorization: Bearer <token>` header. The `X-Is-Internal` header bypasses auth only for internal recommendation endpoints, not for `/api/pizza`.

### Mobile apps — build environment

This VM has the toolchains to build all three **Android** APKs. iOS apps cannot be built (requires macOS + Xcode).

**Android emulator (software rendering, no KVM):**
An AVD named `quickpizza-test` (Android 14, x86_64, google_apis) is pre-created. KVM is not available, so the emulator runs with software rendering (`-no-accel -gpu swiftshader_indirect`). Key characteristics:
- **Boot time:** ~7–8 minutes.
- **Performance:** Very slow. Jetpack Compose apps (Android native) trigger frequent ANR ("app isn't responding") dialogs. Flutter apps are somewhat more responsive.
- **Disable animations** to reduce ANRs: `adb shell settings put global window_animation_scale 0 && adb shell settings put global transition_animation_scale 0 && adb shell settings put global animator_duration_scale 0`
- **Backend connectivity:** The emulator reaches the host at `10.0.2.2`, so apps with empty `BASE_URL` default to `http://10.0.2.2:3333`, which maps to the local QuickPizza backend.
- **Launch command:** `emulator -avd quickpizza-test -no-window -no-audio -no-accel -gpu swiftshader_indirect -memory 2048 -no-snapshot -no-boot-anim &`
- **Wait for boot:** `adb wait-for-device && while [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; do sleep 10; done`
- **Best for:** Smoke-testing that APKs install and launch. Not practical for full UI automation due to extreme slowness.
- **Recommended for real automation:** BrowserStack (see below).

**Installed toolchains:**
- **Android SDK** at `/opt/android-sdk` — platform 36, build-tools 36.0.0, NDK 27.1.12297006 + 28.2.13676358. Env vars `ANDROID_HOME`/`ANDROID_SDK_ROOT` set in `~/.bashrc`.
- **Flutter** 3.41.9 (Dart 3.11.5) at `/opt/flutter`. On `PATH` via `~/.bashrc`.
- **JDK 21** (system, `/usr/bin/java`). Works for all three Gradle builds.
- **Yarn** 1.22.22 (via nvm) for React Native.

**Build commands (from `/workspace`):**

| App | Build command | APK output |
|-----|--------------|------------|
| Flutter | `cd Mobiles/flutter && flutter pub get && flutter build apk --debug --dart-define-from-file=config.json` | `Mobiles/flutter/build/app/outputs/flutter-apk/app-debug.apk` |
| React Native | `cd Mobiles/react-native && yarn install && cd android && ./gradlew assembleDebug` | `Mobiles/react-native/android/app/build/outputs/apk/debug/app-debug.apk` |
| Android native | `cd Mobiles/android && ./gradlew assembleDebug` | `Mobiles/android/app/build/outputs/apk/debug/app-debug.apk` |

**Config files:** Each app needs a `config.json` copied from its `.example` template:
- Flutter: `Mobiles/flutter/config.json` (from `config.json.example`) — `FARO_COLLECTOR_URL`, `BASE_URL`, `PORT`.
- React Native: `Mobiles/react-native/config.json` (from `config.json.example`) — same fields.
- Android native: `Mobiles/android/app/src/main/res/raw/config.json` (from root `config.json.example`) — `OTLP_ENDPOINT`, `OTLP_INSTANCE_ID`, `OTLP_API_KEY`, `BASE_URL`.

### BrowserStack integration

**BrowserStack Local** binary is installed at `/usr/local/bin/BrowserStackLocal` (v8.9). It creates a tunnel from BrowserStack devices to the local QuickPizza backend.

**Credentials:** `BROWSERSTACK_USERNAME` and `BROWSERSTACK_ACCESS_KEY` environment secrets.

**Running apps on BrowserStack with local backend:**
1. Start the QuickPizza backend: `make dev` or `./bin/quickpizza` (port 3333).
2. Start BrowserStack Local tunnel: `BrowserStackLocal --key $BROWSERSTACK_ACCESS_KEY --local-identifier quickpizza-tunnel &`
3. Upload APK: `curl -u "$BROWSERSTACK_USERNAME:$BROWSERSTACK_ACCESS_KEY" -X POST https://api-cloud.browserstack.com/app-automate/upload -F "file=@<path-to-apk>"`
4. Use the returned `bs://` URL with `takeAppScreenshot` or `runAppTestsOnBrowserStack` MCP tools, setting `browserstack.local=true` and `browserstack.localIdentifier=quickpizza-tunnel` in capabilities.
5. In the app's `config.json`, set `BASE_URL` to `http://localhost:3333` — BrowserStack Local routes `localhost` from the device through the tunnel to this VM.

**Note:** The BrowserStack free trial may have expired. Check plan status: `curl -u "$BROWSERSTACK_USERNAME:$BROWSERSTACK_ACCESS_KEY" https://api-cloud.browserstack.com/app-automate/plan.json`

### Grafana Cloud CLI (gcx)

**gcx** (v0.2.14) is installed at `/usr/local/bin/gcx` with 19 agent skills in `~/.agents/skills/`. Use it to verify that mobile app telemetry lands correctly in Grafana Cloud.

**Authentication:** Set these environment secrets (or use `gcx login`):
- `GRAFANA_SERVER` — Grafana Cloud instance URL (e.g. `https://<stack>.grafana.net`)
- `GRAFANA_TOKEN` — Grafana service account token (Editor/Admin role)
- `GRAFANA_CLOUD_TOKEN` — Cloud Access Policy token (needed for `gcx frontend`, `gcx traces`, etc.)

**Telemetry verification commands for mobile apps:**

| What to check | Command |
|---------------|---------|
| Faro apps (Flutter, RN) | `gcx frontend apps list` |
| Faro app details | `gcx frontend apps get <app-id>` |
| OTel traces (iOS, Android native) | `gcx traces query '{resource.service.name="quickpizza-android"}' --since 1h` |
| OTel logs (iOS, Android native) | `gcx logs query '{service_name="quickpizza-android"}' --since 1h` |
| Explore available datasources | `gcx datasources list` |
| Check connection | `gcx config check` |

**Where each app's telemetry lands (from `CLAUDE.md`):**
- Flutter + React Native → Grafana Cloud **Frontend Observability** (Faro)
- iOS native + Android native → Grafana Cloud **Tempo + Loki** (OTLP/HTTP)

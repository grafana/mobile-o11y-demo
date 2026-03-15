# AGENTS.md

## Cursor Cloud specific instructions

### Project Overview

This repo is a mobile observability demo. It contains:

1. **QuickPizza web app** — Go backend + SvelteKit frontend monolith (serves on `:3333`). Uses in-memory SQLite by default.
2. **Flutter mobile app** (`Mobiles/flutter/`) — Cross-platform app (Android/iOS) using Dart, Riverpod, and Grafana Faro SDK.
3. **Native iOS app** (`Mobiles/ios/`) — Swift/SwiftUI app with OpenTelemetry. Requires macOS/Xcode (cannot build on Linux).

No React Native or standalone native Android app exists in the repo currently.

### Services

| Service | Location | How to run |
|---------|----------|------------|
| QuickPizza backend + web UI | Root | `make build-web && go build -o bin/quickpizza ./cmd && ./bin/quickpizza` |
| Flutter app (Android APK) | `Mobiles/flutter/` | `flutter pub get && flutter build apk --debug --dart-define-from-file=config.json` |

The backend must be running for the Flutter app to work (it connects to the QuickPizza API).

### QuickPizza Web App Commands

Standard dev commands are in `CLAUDE.md` and `docs/development.md`:

- **Frontend install/build:** `make build-web`
- **Backend build:** `go build -o bin/quickpizza ./cmd`
- **Run server:** `./bin/quickpizza` (all services enabled by default)
- **Frontend lint:** `cd pkg/web && npm run biome-check`
- **Frontend type-check:** `cd pkg/web && npm run check` (has pre-existing errors — not blocking)
- **Go vet:** `go vet ./...`

### Flutter App Commands

See `Mobiles/flutter/README.md` for full details:

- **Install deps:** `cd Mobiles/flutter && flutter pub get`
- **Config:** `cp config.json.example config.json` (edit `FARO_COLLECTOR_URL` if needed; `BASE_URL` defaults to `10.0.2.2:3333` for Android emulator)
- **Build APK:** `flutter build apk --debug --dart-define-from-file=config.json`
- **Lint:** `flutter analyze`
- **Tests:** `flutter test`

### SDK Locations

- **Flutter SDK:** `/opt/flutter` (added to PATH via `~/.bashrc`)
- **Android SDK:** `/opt/android-sdk` (`ANDROID_HOME` / `ANDROID_SDK_ROOT`)
- **Android cmdline-tools:** `/opt/android-sdk/cmdline-tools/latest/bin/`

### Non-obvious Caveats

- **Frontend build requires env vars:** Running `npm run build` directly in `pkg/web` fails because `PUBLIC_BACKEND_ENDPOINT` and `PUBLIC_BACKEND_WS_ENDPOINT` must be exported (even as empty strings). Always use `make build-web`.
- **Go dependencies are vendored:** The `vendor/` directory is committed. No `go mod download` is needed.
- **Frontend lockfile:** `package-lock.json` exists in `pkg/web/` — use `npm` (not yarn/pnpm).
- **Authentication for API calls:** Most API endpoints require a user token. Create a user via `POST /api/users` with `{"username":"...","password":"..."}`, then login via `POST /api/users/token/login` to get a token. Pass it as `Authorization: Token <token>`. Default credentials: username `default`, password `12345678`.
- **Faro/telemetry warnings are harmless:** Console warnings about "Grafana Faro is not configured" are expected when `QUICKPIZZA_CONF_FARO_URL` is not set.
- **gRPC ports:** The server also opens `:3334` (gRPC) and `:3335` (gRPC health check) in addition to `:3333`.
- **Flutter config.json:** Must exist before building. Copy from `config.json.example`. The `FARO_COLLECTOR_URL` can be a placeholder for local dev.
- **Flutter widget test:** `test/widget_test.dart` has a pre-existing failure (`QuickPizza app loads`). The other 6 tests pass.
- **No Android emulator in Cloud VM:** You can build APKs but cannot run the emulator (no KVM/hardware acceleration). Use `flutter build apk --debug` to verify builds.
- **iOS apps cannot build on Linux:** The native iOS app and Flutter iOS target require macOS + Xcode.
- **On-device testing (future):** BrowserStack + Appium will be used for testing on real devices. Not set up yet — will be configured separately.

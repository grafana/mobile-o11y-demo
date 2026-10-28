# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

QuickPizza is a demonstration web application that generates pizza recommendations. It's built with a Go backend and SvelteKit frontend, designed for k6 load testing workshops and observability demonstrations.

The repository also contains **four QuickPizza mobile demo apps** under `Mobiles/` that demonstrate mobile observability against the same backend. See [Mobile Apps](#mobile-apps-mobiles) below.

## Key Commands

### Building & Running
- `make build` - Build frontend and backend together
- `make build-go` - Build only Go backend (doesn't rebuild frontend)
- `docker build -t quickpizza-mobile-local:development . && docker run --rm -it -p 3333:3333 quickpizza-mobile-local:development` - Build and run backend for mobile (see root README `QUICKPIZZA_IMAGE`)

### Frontend Development
- `cd pkg/web && npm install` - Install frontend dependencies
- `cd pkg/web && npm run dev` - Start development server
- `cd pkg/web && npm run build` - Build production frontend
- `cd pkg/web && npm run biome-check` - Check frontend code
- `cd pkg/web && npm run biome-format` - Format frontend code

### Go Development
- `make format` - Format Go code with goimports
- `make format-check` - Check Go formatting
- `make proto` - Generate protobuf files from proto/quickpizza.proto

### Testing
- `./k6/run-tests.sh` - Run k6 tests (requires k6 installed)
- `./k6/run-tests.sh -u http://localhost:3333 -t "k6/foundations/*.js"` - Run specific tests
- All k6 tests are in the `k6/` directory organized by category

### Docker Development
- `make docker-build` - Build local Docker image
- `make docker-run` - Run local container with volume mounts

## Architecture

### Microservices Architecture
The application is designed as a modular monolith that can be deployed as separate microservices. Services are controlled by environment variables:

- **PublicAPI** (`QUICKPIZZA_ENABLE_PUBLIC_API_SERVICE`) - Serves Frontend and Gateway
- **Frontend** -  Serves SvelteKit UI
- **Gateway** - Routes requests between services in microservice deployments
- **Catalog** (`QUICKPIZZA_ENABLE_CATALOG_SERVICE`) - Manages ingredients, tools, doughs, users, ratings
- **Copy** (`QUICKPIZZA_ENABLE_COPY_SERVICE`) - Handles quotes, names, adjectives for pizza generation
- **Recommendations** (`QUICKPIZZA_ENABLE_RECOMMENDATIONS_SERVICE`) - Core pizza recommendation logic
- **WebSocket** (`QUICKPIZZA_ENABLE_WS_SERVICE`) - Real-time communication
- **gRPC** (`QUICKPIZZA_ENABLE_GRPC_SERVICE`) - gRPC service on ports 3334/3335
- **Config** (`QUICKPIZZA_ENABLE_CONFIG_SERVICE`) - Configuration endpoint
- **HTTP Testing** (`QUICKPIZZA_ENABLE_HTTP_TESTING_SERVICE`) - HTTP testing utilities
- **Test K6 IO** (`QUICKPIZZA_ENABLE_TEST_K6_IO_SERVICE`) - Legacy test.k6.io replacement endpoints

### Key Packages
- `pkg/http/` - Main HTTP server and route handlers
- `pkg/database/` - Database abstraction (supports SQLite and PostgreSQL)
- `pkg/grpc/` - gRPC server implementation
- `pkg/web/` - SvelteKit frontend embedded in Go binary
- `pkg/model/` - Data models (Pizza, User, Ingredient, etc.)
- `pkg/errorinjector/` - Error injection for testing via headers

### Database
- Default: In-memory SQLite (`file::memory:?cache=shared`)
- Configurable via `QUICKPIZZA_DB` environment variable
- Supports PostgreSQL with `postgres://` connection strings
- Uses Bun ORM with migrations in `pkg/database/migrations/`

### Observability
Comprehensive observability built-in:
- **Tracing**: OpenTelemetry with configurable OTLP endpoint
- **Metrics**: Prometheus metrics on `/metrics` endpoint
- **Logging**: Structured JSON logging with slog
- **Profiling**: Pyroscope integration for continuous profiling
- **Frontend Observability**: Grafana Faro support

### Environment Configuration
- `QUICKPIZZA_ENABLE_ALL_SERVICES` - Enable all services (default: true)
- `QUICKPIZZA_LOG_LEVEL` - Set logging level (default: info)
- `QUICKPIZZA_OTLP_ENDPOINT` - OpenTelemetry collector endpoint
- `QUICKPIZZA_OTEL_RECORD_BODIES` - Adds redacted HTTP request/response bodies to server spans as `http.request.body` / `http.response.body` events (default: off)
- `QUICKPIZZA_PYROSCOPE_ENDPOINT` - Pyroscope server for profiling
- `QUICKPIZZA_DB` - Database connection string

## Mobile Apps (`Mobiles/`)

Four QuickPizza clients that share screens, workflows, and an in-app **Debug** tab (config overrides, backend error/latency injection, test logs, handled exceptions, native crashes) but use different telemetry SDKs. All four send to the Grafana Cloud **Faro collector** and land in Frontend Observability.

Docs (read these instead of restating them here):

- [`Mobiles/README.md`](./Mobiles/README.md): entry point; run the backend and an app.
- [`Mobiles/docs/CONNECT_GRAFANA_CLOUD.md`](./Mobiles/docs/CONNECT_GRAFANA_CLOUD.md): collector URLs, config keys, legacy OTLP gateway.
- [`Mobiles/docs/MOBILE_OBSERVABILITY_OVERVIEW.md`](./Mobiles/docs/MOBILE_OBSERVABILITY_OVERVIEW.md): what each app emits and where it lands.
- Per-platform READMEs under `Mobiles/<platform>/README.md`; SDK gaps in [`Mobiles/docs/OTEL_MOBILE_MATURITY.md`](./Mobiles/docs/OTEL_MOBILE_MATURITY.md).

| App | SDK | Endpoint (config key) | Faro app (id) | Config file |
| --- | --- | --- | --- | --- |
| `Mobiles/flutter/` | Faro Flutter SDK | `/collect/<appKey>` (`FARO_COLLECTOR_URL` or per-platform key, required) | `QuickPizza_Flutter` (69) | `config.json` |
| `Mobiles/react-native/` | Faro React Native SDK | `/collect/<appKey>` (`FARO_COLLECTOR_URL` or per-platform key, required) | `QuickPizza_ReactNative` (123) | `config.json` |
| `Mobiles/ios/` | `opentelemetry-swift` via the local `grafana-opentelemetry-ios` package | `/otlp/<appKey>` (`OTLP_ENDPOINT`, no auth) | `QuickPizza_iOS` (204) | `Config.xcconfig` |
| `Mobiles/android/` | `opentelemetry-android` RUM agent via the local `grafana-opentelemetry-android` library | `/otlp/<appKey>` (`OTLP_ENDPOINT`, no auth) | `QuickPizza_Android` (182) | `app/src/main/res/raw/config.json` |

Gotchas worth knowing before changing mobile code or docs:

- **Backend image:** mobile uses `quickpizza-mobile-local:development`, built from this checkout (`docker build -t quickpizza-mobile-local:development .`). Compose defaults to the upstream k6 image unless `QUICKPIZZA_IMAGE` is set. `ghcr.io/grafana/quickpizza-mobile-local` is only published on releases.
- **Native apps without `OTLP_ENDPOINT`** run, but OpenTelemetry is not initialized. `OTLP_INSTANCE_ID` / `OTLP_API_KEY` are only for the legacy OTLP gateway, which keeps data as raw OTel in Tempo + Loki (invisible to the Frontend Observability plugin).
- **Faro OTLP ingest** accepts traces and logs only (metrics are disabled in both native apps) and requires `session.id` on every signal.
- **Flutter also runs "DemoRum"**, a made-up no-op second RUM SDK that shows two SDKs coexisting. It is intentional, not something to clean up. See `Mobiles/flutter/README.md`.
- **iOS** emits no automatic screen or lifecycle events; `app.screen.view` is manual, and crashes/hangs come from MetricKit (delayed, OS-controlled).
- **Android** emits no `screen.view` event. Screens appear as `screen.name` on spans (always `MainActivity`) and as Compose `app.navigation.complete` events; the collector derives Faro `view_changed` from both.
- **JDK:** native Android uses Android Studio's bundled JDK; Flutter and React Native Android need JDK 17.
- **Versions:** don't restate SDK versions here. They are pinned in `pubspec.yaml`, `package.json`, `Package.resolved` and `libs.versions.toml`.

### Telemetry CI (`.github/workflows/mobile_demo_telemetry.yaml`)

Runs every 2 h on `main`, on push, and via `workflow_dispatch`. Two jobs — Android (emulator) and iOS (simulator) — each exercise all three apps, so six app×platform combinations per run.

- **The driver is [Arbigent](Mobiles/e2e/), an AI UI agent**, not a scripted tap sequence. Scenarios are natural-language goals with `maxRetry` / `maxStep` budgets, so the run needs `OPENAI_API_KEY`.
- **Three flows.** The basic pizza flow runs every time. Handled-exception runs every ~6 h (`schedule_bucket % 3`). Crash diagnostics runs every ~20 h (`% 10`), which suppresses the handled-exception flow on that run. `workflow_dispatch` runs the basic flow only, unless you pass `run_diagnostics=true`.
- **A green run does not prove telemetry arrived.** The exporters are fire-and-forget and the e2e tests pass either way, so a wrong or 404 ingest URL still produces a green run. Confirm by querying the stack for the app.
- **The `mobile-demo-telemetry` environment uses a branch allow-list.** You can dispatch from a feature branch and still get the Vault secrets, but only if the branch is listed: `gh api repos/grafana/mobile-o11y-demo/environments/mobile-demo-telemetry/deployment-branch-policies`.

## Development Notes

### Error Injection
The application supports error injection via HTTP headers for testing:
- `x-error-record-recommendation` - Trigger recommendation errors
- `x-error-get-ingredients` - Trigger ingredient retrieval errors
- `x-delay-record-recommendation` - Add delays to recommendations
- `x-delay-get-ingredients` - Add delays to ingredient retrieval
- Add `-percentage` suffix to any error header to control probability

### Frontend Integration
- Frontend is built with SvelteKit and embedded in the Go binary
- Uses Vite for development builds
- Supports Grafana Faro for frontend observability
- WebSocket integration for real-time updates

### Authentication
- Token-based authentication with user management
- Admin endpoints with separate admin authentication
- CSRF protection for cookie-based authentication
- Authentication middleware can be bypassed with `X-Is-Internal` header

### Testing with k6
The application is specifically designed for k6 load testing:
- Extensive k6 test suite in `k6/` directory
- Support for k6 browser testing
- k6 extensions and disruptor examples
- Prometheus output for k6 metrics correlation

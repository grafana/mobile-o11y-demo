# AGENTS.md

## Cursor Cloud specific instructions

### Project Overview

QuickPizza is a Go backend + SvelteKit frontend monolith that generates pizza recommendations. It uses in-memory SQLite by default (no external database required).

### Key Commands

Standard dev commands are documented in `CLAUDE.md` and `docs/development.md`. Key references:

- **Frontend install/build:** `make build-web` (sets required env vars `PUBLIC_BACKEND_ENDPOINT` and `PUBLIC_BACKEND_WS_ENDPOINT` automatically)
- **Backend build:** `go build -o bin/quickpizza ./cmd`
- **Run server:** `./bin/quickpizza` (serves on `:3333`, all services enabled by default)
- **Frontend lint:** `cd pkg/web && npm run biome-check`
- **Frontend type-check:** `cd pkg/web && npm run check` (has pre-existing errors in repo — not blocking)
- **Go vet:** `go vet ./...`
- **Go format check:** `make format-check` (requires `goimports` — not installed by default)

### Non-obvious Caveats

- **Frontend build requires env vars:** Running `npm run build` directly in `pkg/web` fails because `PUBLIC_BACKEND_ENDPOINT` and `PUBLIC_BACKEND_WS_ENDPOINT` must be exported (even as empty strings). Always use `make build-web` instead of bare `npm run build`.
- **Go dependencies are vendored:** The `vendor/` directory is committed. No `go mod download` is needed.
- **Frontend lockfile:** `package-lock.json` exists in `pkg/web/` — use `npm` (not yarn/pnpm).
- **Authentication for API calls:** Most API endpoints require a user token. Create a user via `POST /api/users` with `{"username":"...","password":"..."}`, then login via `POST /api/users/token/login` to get a token. Pass it as `Authorization: Token <token>`.
- **Login page hints:** The login page shows default credentials hint: username `default`, password `12345678`.
- **Faro/telemetry warnings are harmless:** Console warnings about "Grafana Faro is not configured" are expected when `QUICKPIZZA_CONF_FARO_URL` is not set. They don't affect functionality.
- **gRPC ports:** When the server runs, it also opens `:3334` (gRPC) and `:3335` (gRPC health check) in addition to `:3333` (HTTP).

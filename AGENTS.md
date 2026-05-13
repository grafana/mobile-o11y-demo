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

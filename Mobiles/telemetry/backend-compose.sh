#!/usr/bin/env bash
# Run the existing Linux backend with an optional private Alloy configuration.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
ARGS=(-f compose.grafana-cloud.microservices.yaml -f compose.grafana-cloud.dev-override.yaml)
if [[ "${TELEMETRY_PROFILE:-default}" == dual-stack ]]; then
  ARGS+=(-f "${MOBILE_TELEMETRY_RUN_DIR:-Mobiles/telemetry/.runtime/ci}/compose.json")
fi
if [[ "${1:-}" == drain ]]; then
  docker compose "${ARGS[@]}" stop catalog config copy public-api recommendations ws grpc quickpizza-db
  # Drain the existing Docker Alloy after producers stop. The native supervisor
  # handles the mobile OTLP queues and in-flight Faro mirrors separately.
  python3 - <<'PY'
import sys, time
sys.path.insert(0, 'Mobiles/telemetry')
from telemetry import queues_empty
for _ in range(30):
    try:
        if queues_empty(12345):
            time.sleep(2)
            if queues_empty(12345):
                break
    except OSError:
        pass
    time.sleep(1)
else:
    print('Backend OTLP drain deadline reached; delivery may be incomplete.', file=sys.stderr)
PY
else
  docker compose "${ARGS[@]}" "$@"
fi

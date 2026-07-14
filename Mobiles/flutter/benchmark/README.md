# Flutter QuickPizza telemetry replay

This local-only harness captures real Faro payloads from the Flutter QuickPizza app, keeps the raw request bodies unchanged, creates a sanitized copy, and replays the same telemetry mix with fresh timestamps and correlated IDs.

It intentionally does not send data to Grafana Cloud or any shared development stack.

## Prerequisites

- Flutter
- Go
- Node.js 22 or newer
- Grafana Alloy with `faro.receiver`
- Loki
- An iOS simulator or Android emulator

## Capture one session

Start the local telemetry stack:

```bash
cd Mobiles/flutter/benchmark
node local-stack.mjs
```

In another terminal, start the byte-preserving proxy. Use a new capture directory for every scenario:

```bash
node capture-proxy.mjs \
  --output .captures/flutter-session-001 \
  --scenario launch-request-rate-background-foreground
```

Run the QuickPizza backend from the repository root:

```bash
make build-go
./bin/quickpizza
```

Run the Flutter app with the proxy as its collector:

```bash
cd Mobiles/flutter
flutter run \
  --dart-define=FARO_COLLECTOR_URL=http://127.0.0.1:12348/collect/local-benchmark-key \
  --dart-define=BASE_URL=http://127.0.0.1:3333 \
  --dart-define=PORT=3333
```

Complete the named scenario once, allow the Faro batch to flush, then stop the app and proxy. Files under `.captures/<capture>/raw` are the exact HTTP request bodies and must not be edited.

Captured payloads can contain user or device identifiers. The entire `.captures` directory is ignored by Git. Only sanitized summaries should be committed.

## Sanitize and prepare replay

```bash
node prepare-replay.mjs \
  --capture .captures/flutter-session-001 \
  --run flutter-session-001-replay
```

The command:

- preserves the raw capture and records its SHA-256 hashes;
- replaces user and installation identifiers in a separate sanitized copy;
- rejects remaining obvious credentials or email addresses;
- shifts timestamps while preserving their relative spacing;
- remaps session, page, action, trace, and span IDs consistently;
- adds `benchmark_run_id` as a session attribute;
- fails if source and replay item counts differ.

## Replay and validate Sessions

```bash
node replay.mjs \
  --input .captures/flutter-session-001/replay/flutter-session-001-replay

node validate-loki.mjs --run flutter-session-001-replay
```

The validation runs the same lifecycle-event shape used by Mobile O11y Sessions and requires at least one parsed `session_id`.

## Recorded validations

Sanitized capture and replay summaries live under [`results`](results). Raw payloads remain local and are not committed.

## Tests

```bash
node --test lib/*.test.mjs
alloy validate config/alloy.local.alloy
loki -config.file=config/loki.local.yaml -verify-config
```

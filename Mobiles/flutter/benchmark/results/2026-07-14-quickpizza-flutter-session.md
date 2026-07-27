# QuickPizza Flutter local replay validation

## Source

- App: `QuickPizza_Flutter` `1.1.1`
- SDK: `faro-mobile-flutter` `0.17.0-beta.1`
- Scenario: launch, request one pizza, rate it, background the app, and resume it
- Destination: local Alloy and Loki only
- Capture: 19 HTTP batches containing one session

The byte-for-byte source payloads remain in the ignored local `.captures` directory. The replay manifest records their SHA-256 hashes. The derived data removes the source user, installation, and device identifiers, and the sanitization check found no remaining obvious credentials or email addresses.

## Counts

| Signal | Source | Replay |
| --- | ---: | ---: |
| Events | 19 | 19 |
| Measurements | 28 | 28 |
| Logs | 8 | 8 |
| Exceptions | 0 | 0 |
| Trace spans | 5 | 5 |
| Total | 60 | 60 |

The replay changed timestamps and correlated identifiers, added `benchmark_run_id`, and preserved the source signal mix and item counts. None of the 15 source identifiers found across Faro and OTLP fields remained in the replayed payloads.

## Sessions validation

The Mobile O11y Sessions lifecycle query returned one lifecycle row for one remapped session after replay into local Loki.

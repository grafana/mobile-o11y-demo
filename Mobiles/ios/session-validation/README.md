# Native iOS session validation (#99)

Validation harness for [#99](https://github.com/grafana/frontend-o11y-knowledge-workbench/issues/99),
part of [#57](https://github.com/grafana/frontend-o11y-knowledge-workbench/issues/57). It does not
publish an SDK, modify the separately extracted package, or close either issue. The session wiring
under test is described in the package README,
[Sessions](../grafana-opentelemetry-ios/README.md#sessions).

## Version boundary

The Grafana package and QuickPizza pin consolidated OpenTelemetry Swift
[`ce0b2494`](https://github.com/open-telemetry/opentelemetry-swift/commit/ce0b249467c3d28f6340e6e26ff12ee20a8bfe8a),
the merged #1218 commit (includes #1184, #1185, #1222; no separate Swift Core dependency). It is an
unreleased commit. It requires Swift tools 6.2 and iOS 15; don't ship it without agreeing that
adoption boundary and repeating release validation. The emitted SDK version still says `2.6.0`;
the resolved commit identifies what was tested.

## Evidence summary

All runs used loopback-only local collectors. None used hosted ingest, Grafana Cloud or the product UI.

| Date (2026) | Environment | Passed | Not covered |
| --- | --- | --- | --- |
| Oct 15 | Xcode 27, iPhone 17 Pro sim, iOS 27.0 | 104 package tests on macOS and on iOS; 10 session tests under TSan; QuickPizza Debug and Release builds; UIKit probe 8 launches each in Debug and Release, 25 logs/events + 25 spans per run through local Alloy + Faro into Loki/Tempo, no missing or duplicate records, IDs and previous links matched, 8 negative verifier mutations rejected; offline replay after SIGKILL delivered once, not again on the next restart | Physical device, power loss, native crash handler, QuickPizza against a hosted collector |
| Oct 16 | Xcode 27.0, iPhone 18 Pro sim | App Group host + real share extension, Debug and Release: 3 host and 3 extension launches, 50 overlapping resets per role per phase, restore kept ID/link/decision with zero sampler calls, cold start linked previous; same-namespace negative control rejected | Physical device on this harness |
| Oct 16 (Ben, commit `8fada4bc`) | Xcode 27.1, iPhone 16 Pro iOS 27.0.1 + sim | Signed host and extension on a **physical iPhone**, Debug and Release, provisioned App Group; package, TSan, probe and verifier results matched | Later share-sheet discovery fix. His device pass used Favorites; needs a phone rerun without Favorites |
| Oct 16 | Xcode 27.0, iPhone 18 Pro sim | Discovery fix: both UI tests in Debug and Release without whole-test retries; 104 macOS tests | Simulator package suite, TSan, backend probe not rerun |
| Oct 16 | Xcode 27.0, Swift 6.4 | Probe manifest at tools 6.2; probe 8 launches per config incl. offline replay; macOS 6-launch subset; 104 macOS tests | App Group UI tests, device, TSan, Faro backend not rerun |

Runtime cases covered: sampled/unsampled reset, a span retained across reset, delayed historical
logs, linked cold starts, restoring a saved decision under the opposite sampler, automatic
`URLSession` traces with W3C context, app switching, shortened inactivity expiry, and maximum
lifetime despite activity.

Backends: the Oct 15 run used a local Faro snapshot `ae334608` with Alloy 1.16.1, Loki 3.7.6 and
Tempo 3.0.2. Ben used an Oct 7 Faro checkout and Alloy 1.17.0. Don't combine them into one
backend/version claim.

## MetricKit boundary

The probe sets `instrumentation: .init(metricKitDiagnostics: false)`. Delayed MetricKit diagnostics
cannot identify the session active at the original crash; the default `MetricKitInstrumentation()`
uses the global session pipeline at delivery time and can attach the wrong session and decision.
QuickPizza leaves the default on.

For session-aligned adoption, disable that default. If you need MetricKit, give upstream
`MetricKitConfiguration` separate tracer/logger instances without session attribution or sampling,
and validate that route separately. Exact crash-session correlation is unsupported.

## Process and extension ownership

- The package owns one `SessionManager` in one process, using `UserDefaults.standard`. App and
  extension containers are separate; a shared App Group does not share their sessions.
- For explicit upstream persistence, use one stable namespace per process role and one writer per
  suite/namespace (for example `app` and `share-extension` in the same App Group suite). Changing a
  namespace abandons its continuity. Never use a random namespace per launch.
- `.exclusive` is a caller ownership contract, not a cross-process lock. `.shared` throws
  `concurrentWritersUnsupported` without touching storage. Two live managers must never write the
  same suite/namespace.

```swift
let persistence = UserDefaultsSessionPersistence(
  userDefaults: provisionedAppGroupDefaults, namespace: "share-extension"
)
let manager = try SessionManager(
  configuration: sessionConfig, persistence: persistence, persistenceAccess: .exclusive
)
```

This is upstream configuration, not a package option. Don't register a custom manager and then
call `GrafanaOtel.initialize`; the package installs its own. Not all bundled instrumentations are
claimed to be extension-safe.

The `app-group/` harness runs a UIKit host and a real share extension using only the upstream
`Sessions` product. It requires `containerURL(forSecurityApplicationGroupIdentifier:)` to succeed in
both processes and never falls back to a temporary directory.

## Remaining before closing #99

1. Review and adopt the Grafana integration and its iOS 15 / Swift tools 6.2 boundary with the
   package owner. Keep package extraction and release (#150) separate.
2. Reconcile #99, #57's gap matrix and the Mobile O11y guides with this evidence and the MetricKit,
   metric and extension limitations.

Still unverified: a telemetry probe on a physical device (`run.mjs` uses `simctl` and loopback),
minimum-iOS runtime, full 15-minute and 4-hour waits, MetricKit attribution, hosted ingest,
product UI, power-loss durability, released-package installation, and share-sheet discovery
without Favorites on a phone. #57 also has separate Android work.

## Reproduction

Use a disposable, dedicated simulator. Run one test at a time. Never use hosted apps or
production credentials.

### Package tests

From `Mobiles/ios/grafana-opentelemetry-ios`:

```bash
swift test --enable-code-coverage
swift test --sanitize=thread --filter GrafanaOtelSessionSamplingTests
xcodebuild -scheme grafana-opentelemetry-ios -destination "id=$SIMULATOR_ID" \
  -derivedDataPath /tmp/session99-package-ios CODE_SIGNING_ALLOWED=NO test
```

### Telemetry probe

From this directory, with Node 24, Alloy 1.16.1 at `/opt/homebrew/bin/alloy`, Ruby with
`xcodeproj` 1.27.0, and a booted dedicated simulator:

```bash
ruby create-project.rb
xcodebuild -project Session99Probe.xcodeproj -scheme Session99Probe -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/session99-probe-ios \
  CODE_SIGNING_ALLOWED=NO build
SESSION99_SIMULATOR="$SIMULATOR_ID" \
SESSION99_FARO_ENDPOINT="http://127.0.0.1:18000/otlp/$LOCAL_APP_KEY" \
node run.mjs /tmp/session99-probe-ios/Build/Products/Debug-iphonesimulator/Session99Probe.app
node verify-backend.mjs run-<printed-run-id> <local-app-id>
```

Repeat with `Release`. `run.mjs` starts and stops its own Alloy receiver, test HTTP server and
fault-injecting relay. It installs and terminates only `net.local.varanha.session99` and opens
Safari to drive foreground/background transitions.

`SESSION99_FARO_ENDPOINT` is optional for collector-only checks and must use `127.0.0.1`. Backend
verification also needs a local Faro mobile app forwarding to Loki on 13100 and Tempo on 13200. That
fixture is not in this repository.

macOS process-only subset (6 launches, no UIKit lifecycle; not an iOS replacement):

```bash
swift build
node run.mjs "$(swift build --show-bin-path)/Session99Probe"
```

### App Group host and extension (simulator)

From `app-group/`, with Ruby and `xcodeproj` 1.27.0:

```bash
ruby create-project.rb
xcodebuild -project Generated/Session99Groups.xcodeproj -scheme Session99Groups \
  -configuration Debug -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath /tmp/session99-groups \
  -resultBundlePath /tmp/session99-groups-debug.xcresult \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO -collect-test-diagnostics never CODE_SIGN_IDENTITY=- test
```

Repeat with `Release` and a new result-bundle path.

- Do **not** set `CODE_SIGNING_ALLOWED=NO` for simulator runs: the App Group must be declared to
  the simulator. Local ad-hoc signing needs no Apple account.
- Host and extension target iOS 15; the UI-test runner targets iOS 17 (XCTest minimum).
- The test exports no telemetry. Each run leaves test namespaces and evidence files in the App
  Group container.
- Use English system labels. The UI test retries share-sheet discovery (up to three sheets, 45 s);
  don't add blanket test retries that would hide a session or entitlement failure.

### App Group on a physical device

1. Generate with approved, unique identifiers:
   `SESSION99_BUNDLE_PREFIX=<approved-bundle-id> SESSION99_APP_GROUP=<approved-group-id> ruby create-project.rb`.
   Configure signing **after** generating; rerunning overwrites the project.
2. In the Apple Developer portal (Raintank team), register or find the App Group under
   **Certificates, Identifiers & Profiles > Identifiers > App Groups**. It must match
   `SESSION99_APP_GROUP` exactly. See Apple's
   [registration steps](https://developer.apple.com/help/account/identifiers/register-an-app-group/).
3. Register both App IDs, `<approved-bundle-id>` and `<approved-bundle-id>.Session99Share`, enable
   App Groups, and **select the group** on both. Enabling the capability with an empty group list is
   not enough.
4. In Xcode → **Signing & Capabilities**, choose the team and development signing for host,
   extension and UI-test runner. Check the group on host and extension for Debug and Release. See
   Apple's [Xcode setup](https://developer.apple.com/documentation/xcode/configuring-app-groups).
5. Connect, trust and unlock the device, enable Developer Mode, and let Xcode refresh profiles.

`xcodebuild -allowProvisioningUpdates` is not a substitute for step 3: it registers the App IDs with
the capability but leaves their group selections empty. Then:

```bash
xcodebuild -project Generated/Session99Groups.xcodeproj -scheme Session99Groups \
  -configuration Debug -destination "platform=iOS,id=$DEVICE_ID" \
  -resultBundlePath /tmp/session99-groups-device-debug.xcresult \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM_ID" test
```

Repeat with `Release`. Record the commit, device/OS, signing identities, entitlements and JSON
attachments. For discovery validation, keep the extension out of Favorites and use a fresh install.

Unsigned device-target compile only:

```bash
xcodebuild -project Generated/Session99Groups.xcodeproj -scheme Session99Groups \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/session99-groups \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO build
```

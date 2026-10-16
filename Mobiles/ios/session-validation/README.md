# Native iOS session validation (#99)

Local validation candidate for [#99](https://github.com/grafana/frontend-o11y-knowledge-workbench/issues/99),
part of [#57](https://github.com/grafana/frontend-o11y-knowledge-workbench/issues/57).
This does not publish an SDK, modify Ben's extracted package, or close either issue.

## Version boundary

The local Grafana composition package and QuickPizza pin consolidated OpenTelemetry Swift
[`ce0b249467c3d28f6340e6e26ff12ee20a8bfe8a`](https://github.com/open-telemetry/opentelemetry-swift/commit/ce0b249467c3d28f6340e6e26ff12ee20a8bfe8a),
the merged #1218 commit. #1184, #1185 and #1222 are included. There is no separate Swift Core dependency.

This is an unreleased commit, not a new published package version. It requires Swift tools 6.2 and
iOS 15. That is a compatibility change from the spike's Swift tools 6.0 / iOS 13 floor with OTel 2.6.0;
do not ship the dependency update without agreeing that adoption boundary and repeating release validation.
The SDK's emitted version attribute still says 2.6.0; the resolved commit, not that attribute, identifies this test.

## Integration under test

- One explicit `SessionManager` supplies both `SessionTraceSampler` and `SessionSamplingLogRecordProcessor`.
- The trace sampler replaces `SessionSpanProcessor`; a second attribution lookup could race a reset.
- The log filter wraps all downstream processors, before batching and disk buffering. Accepted disk records
  replay without consulting the new session's decision.
- The experimental session sampler defaults to always-on. The default trace delegate remains parent-based,
  so an unsampled trace parent is still respected.
- Grafana defaults remain 900 seconds inactivity, 14,400 seconds maximum lifetime and
  `restorePersistedSession: false`. A new cold-start session links the previously saved ID.
- Session-aware spans/logs count as activity, including background telemetry. This accepted Swift behavior
  is not a promise of user-input-only inactivity tracking.
- Historical logs carry the original `Session.samplingAttributes`. Unknown historical decisions are
  preserved, not sampled using the current session. Capture the snapshot when the event occurs.

## Verified on October 15, 2026

Environment: Apple Silicon host, Xcode 27, iPhone 17 Pro Simulator / iOS 27.0 (24A434).

- Full Grafana package suite: **104 tests passed on macOS and 104 on iOS**, no skipped tests.
- Ten focused session tests passed with Thread Sanitizer. The test executable linked the TSan runtime;
  no race diagnostic was reported. This is bounded stress evidence, not proof that races are impossible.
- macOS coverage for changed implementation files: `GrafanaOtel.swift` 94.69% lines,
  `GrafanaOtelSetup.swift` 100% lines. This excludes the iOS-only MetricKit branch.
- QuickPizza consumer: Debug and optimized Release simulator builds passed with the merged pin.
  The consumer was built using the example configuration, not launched against a hosted collector.
- Independent UIKit probe: Debug and optimized Release each passed **eight separate process launches**.
- Each UIKit run delivered **25 input logs/events and 25 spans** through local Alloy and Faro into
  Loki/Tempo. Faro additionally derived 12 HTTP fetch events, giving **37 stored logs/events** across
  seven sampled session IDs. Unsampled sessions existed but correctly produced no stored telemetry.
- No missing/duplicate records; original session IDs, previous links, timestamps and trace/span IDs matched.
- Eight negative verifier mutations were rejected: missing/duplicate log, wrong log session, missing span,
  wrong derived-event session/trace, wrong span session and missing previous-session link.

The runtime cases cover sampled/unsampled reset, a span retained across reset, delayed historical logs,
linked cold starts, restoring a saved decision under the opposite sampler, automatic `URLSession` traces
and W3C context, app switching, shortened inactivity expiry and maximum lifetime despite activity.

For offline recovery the local relay returns HTTP 503, the app explicitly flushes to disk, then receives
**SIGKILL without SDK shutdown**. An unsampled replacement session replays the accepted original records
once; another restart does not replay them again. This is not immediate-write crash durability, power-loss
durability, a native crash handler test, or a physical-device test.

Final evidence directories (ignored local artifacts):

- Debug: `run-f4bce0ca-04e3-4e44-9d87-c31f25326754/`
- Release: `run-aa782292-399e-4b69-aac8-a8daae2bdcbc/`
- macOS process-only subset: `run-f77a830d-8978-4f8b-9eb9-21012cf4624a/` (six launches, local collector only).
- Package/consumer test and build logs: `run-evidence-20261015/`.

The Debug and Release directories include `result.json` with the executable SHA-256, a command journal,
raw OTLP, Loki/Tempo query responses and `backend-verification.json`. Earlier exploratory runs are not final evidence:
the driver initially reused response filenames between runs and checked process exit before the shutdown
acknowledgment. Both driver errors were corrected. The disk assertion now waits on the writer barrier
instead of racing temporary files. No SDK change was needed for those test-driver issues.

Backend: local Faro source snapshot `ae334608c7c5352006626c4ac746cb5b9a937269`, with session accounting,
OTLP ingestion and compression enabled, forwarding to Loki 3.7.6 and Tempo 3.0.2. This is not Ops,
Grafana Cloud, Pinot or a product-UI verification. All collector addresses are loopback-only.

## Metric recording

This package registers no meter provider. The unit test uses a real OTel counter/reader and an explicit
sum aggregation view to prove recording-time filtering. It records values 2 and 3 under two sampled
snapshots, rejects 100 under the intervening unsampled snapshot, and checks the two exported points.

Capture the session associated with the work, then apply its decision **before aggregation**:

```swift
let session = SessionManagerProvider.getInstance().getSession()
session.recordIfSampled { attributes in
  counter.add(value: 1, attributes: attributes)
}
```

This does not automatically filter other metric instrumentation. The local Faro path does not store
these OTLP metrics; metric tests stop at the SDK exporter, not Grafana metric storage.

## Process and extension ownership

The default package owns one manager in one app process using `UserDefaults.standard`. Standard app
and extension containers are separate; a shared App Group does not make their sessions shared.

For explicit upstream persistence, use one stable namespace per process role and one writer per
suite/namespace. For example, an app and a share extension can use `app` and `share-extension` in the
same provisioned App Group suite. Separate namespaces have independent IDs, previous links and decisions.
Changing namespace abandons that namespace's continuity. Do not use a random namespace on each launch.

```swift
let persistence = UserDefaultsSessionPersistence(
  userDefaults: provisionedAppGroupDefaults, namespace: "share-extension"
)
let manager = try SessionManager(
  configuration: sessionConfig, persistence: persistence, persistenceAccess: .exclusive
)
```

This is an **upstream configuration example**, not a newly exposed Grafana package option. Do not
register a custom manager and then call `GrafanaOtel.initialize`: this candidate installs its own manager.
It does not add a package API for extension configuration or claim that all bundled instrumentations
are extension-safe.

`.exclusive` is a caller ownership contract, not a cross-process lock. `.shared` throws
`concurrentWritersUnsupported` without mutating storage. Two live managers must never write the same
suite/namespace. Read-only inspection or separate namespaces does not coordinate a shared session.

The package namespace unit test uses two managers in one test process. The separate `app-group/`
harness runs a UIKit host and a real share extension, using only the pinned upstream `Sessions` product.
It requires `containerURL(forSecurityApplicationGroupIdentifier:)` to succeed in both processes; it
does not substitute a temporary directory when App Group access fails.

Each test has an isolated run ID, reused across three app launches and extension activations. Within
that run, stable `app` and `extension` namespace suffixes keep the two session chains independent.
The test coordinates overlapping reset loops, restores the saved decisions under the opposite sampler,
then disables restoration to check cold-start linking and new decisions. JSON attachments capture the
process IDs, shared container paths, session snapshots, sampler counts and overlapping time intervals.
It also checks `.shared` rejection without modifying each namespace's stored record. This does not
provide support or coordination for two writers sharing one session namespace.

### App Group verification on October 16, 2026

Environment: Xcode 27.0 (27A266a), iPhone 18 Pro Simulator, iOS 27.0 (24A434), arm64.

- Debug and optimized Release each passed the end-to-end UI test: three host launches and three
  actual share-extension activations. The captured process IDs were distinct across all six launches
  in each configuration, and both roles reported the same App Group container.
- Each role completed 50 resets in both the sampled and unsampled phases, with overlapping reset
  loops. Restore retained the exact ID, previous link and sampled decision with zero sampler calls;
  a subsequent non-restoring startup linked its own previous session and chose the unsampled decision.
- A negative control temporarily used the same namespace for both roles. The test rejected the
  resulting cross-linked chain. Separate namespaces were restored before the final Debug/Release runs.
- The Release host and extension also compiled for `generic/platform=iOS` with signing disabled.
  This is a device-target build only, not installation or physical-device execution.
- Swift formatting and Ruby syntax checks passed. No SDK/package implementation changed in this step;
  the October 15 package/telemetry suites were not rerun for this harness-only addition.

Logs and exported JSON test attachments are in ignored `run-evidence-20261016-app-group/`.
Simulator builds used local ad-hoc signing, not Apple-issued provisioning. Physical-device signing,
App Group provisioning and runtime access remain unverified.

## MetricKit boundary

The runtime probe explicitly sets `instrumentation: .init(metricKitDiagnostics: false)`.
Delayed MetricKit diagnostics cannot reliably identify the session active at the original crash.
Using the current global session pipeline at delivery time can attach the wrong session/decision.
The spike's default `MetricKitInstrumentation()` still uses those globals; this validation does not
declare that default safe for historical attribution.

For session-aligned adoption, disable that default path. If MetricKit is required, supply separate
tracer/logger instances through upstream `MetricKitConfiguration`, without session attribution or
session sampling, and validate that route separately. Exact crash-session correlation remains unsupported.

## Remaining before closing #99

1. Run a **signed app plus actual extension** with provisioned App Group entitlements. Verify the intended
   suite is accessible in both processes, independent namespace chains survive alternating/overlapping
   writes and relaunch, and shared-writer mode is rejected. A development signing identity is now
   available locally, but no physical device or matching local provisioning profiles were available
   during the October 16 check. Simulator ad-hoc signing does not satisfy this device requirement.
2. Review/adopt the narrow Grafana integration and its iOS 15 / Swift tools 6.2 boundary with the package
   owner. Keep package extraction/release (#150) separate; do not silently modify its PR.
3. Reconcile #99, #57's gap matrix and the Mobile O11y guides with this evidence and the explicit MetricKit,
   metric and extension limitations. Shared issues/docs have **not** been changed in this task.

No physical devices, minimum-iOS runtime, full 15-minute/four-hour waits, hosted ingestion, product UI,
power-loss durability or released-package installation were tested here. #57 still has separate Android
work; passing this candidate alone does not complete the cross-platform epic.

## Reproduction

### App Group host and extension

From `session-validation/app-group`, with Ruby plus `xcodeproj` 1.27.0 and a dedicated iOS simulator:

```sh
ruby create-project.rb
xcodebuild -project Generated/Session99Groups.xcodeproj -scheme Session99Groups \
  -configuration Debug -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath /tmp/session99-groups \
  -resultBundlePath /tmp/session99-groups-debug.xcresult \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO -collect-test-diagnostics never CODE_SIGN_IDENTITY=- test
```

Repeat with `Release` and a different result-bundle path. Do **not** set `CODE_SIGNING_ALLOWED=NO`
for simulator execution: the App Group must be declared to the simulator. The generated project uses
local ad-hoc signing, without an Apple account or provisioning request. The host/extension target iOS 15;
the UI-test runner targets iOS 17 because of the current XCTest framework's minimum deployment target.
The test does not export telemetry, submit forms or contact a collector. Use a disposable test simulator:
each run leaves isolated test namespaces and evidence files in its test App Group container.

For a later physical-device run, generate with the approved `SESSION99_BUNDLE_PREFIX` and
`SESSION99_APP_GROUP`, then configure development signing for the app, share extension and test runner.
The generator does not register those identifiers, create profiles or enable automatic provisioning.
Both app and extension must be provisioned for the same App Group. See Apple's
[App Groups setup](https://developer.apple.com/documentation/xcode/configuring-app-groups).
Keep one test running at a time. A simulator pass is not proof of device provisioning or App Group access.

Unsigned device-target compilation, without installing or contacting the provisioning service:

```sh
xcodebuild -project Generated/Session99Groups.xcodeproj -scheme Session99Groups \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/session99-groups \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO build
```

### Package and telemetry integration

From `Mobiles/ios/grafana-opentelemetry-ios`:

```sh
swift test --enable-code-coverage
swift test --sanitize=thread --filter GrafanaOtelSessionSamplingTests
xcodebuild -scheme grafana-opentelemetry-ios -destination "id=$SIMULATOR_ID" \
  -derivedDataPath /tmp/session99-package-ios CODE_SIGNING_ALLOWED=NO test
```

From this directory, with Node 24, Alloy 1.16.1 at `/opt/homebrew/bin/alloy`, Ruby plus `xcodeproj` 1.27.0,
and a dedicated booted iOS simulator:

```sh
ruby create-project.rb
xcodebuild -project Session99Probe.xcodeproj -scheme Session99Probe -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/session99-probe-ios \
  CODE_SIGNING_ALLOWED=NO build
SESSION99_SIMULATOR="$SIMULATOR_ID" \
SESSION99_FARO_ENDPOINT="http://127.0.0.1:18000/otlp/$LOCAL_APP_KEY" \
node run.mjs /tmp/session99-probe-ios/Build/Products/Debug-iphonesimulator/Session99Probe.app
node verify-backend.mjs run-<printed-run-id> <local-app-id>
```

Repeat the build/run with `Release`. Run one probe at a time on the dedicated simulator.
`run.mjs` creates an isolated local Alloy receiver, test HTTP server and fault-injecting relay; it stops
those processes at the end. It installs/terminates only `net.local.varanha.session99` and opens simulator
Safari to exercise foreground/background transitions. Do not use a simulator containing valuable probe data.

`SESSION99_FARO_ENDPOINT` is optional for collector-only checks, and must use host `127.0.0.1`.
Backend verification additionally requires a separately provisioned local Faro mobile app forwarding to
Loki on port 13100 and Tempo on 13200. The October 15 run used a pinned local backend fixture with a fresh
Compose project named `varanha-session99-20261015` and a synthetic app. That fixture and the raw evidence
are not included in this repository; collector-only checks work without them. Do not reuse a hosted app
or production credentials.

For the macOS process-only subset:

```sh
swift build
node run.mjs "$(swift build --show-bin-path)/Session99Probe"
```

That subset has six launches and no UIKit lifecycle transitions. It is not an iOS replacement.

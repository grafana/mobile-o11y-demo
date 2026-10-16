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

### Original App Group simulator verification on October 16, 2026

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
Simulator builds used local ad-hoc signing, not Apple-issued provisioning. The independent device
verification below covers development signing and provisioned App Group access.

### Ben's independent verification on October 16, 2026

[Ben's results](https://github.com/grafana/mobile-o11y-demo/pull/135#issuecomment-6219021189)
are for commit `8fada4bc33fe1514aef70979589c33130ac21eae`, before the share-sheet discovery fixes.
Environment: Xcode 27.1 (27A9275), iOS 27.0 simulator (24A434), and a physical iPhone 16 Pro / iOS 27.0.1.

- The signed host and actual share extension passed in **Debug and Release on the iPhone**. Both used
  Apple Development signing for Raintank and the same provisioned App Group, `group.com.grafana.session99groups`.
- Each configuration used six distinct processes: three host and three extension launches. Both roles
  accessed the same shared container and completed 50 overlapping resets in the sampled/unsampled phases.
  Restore retained the ID, previous link and decision without sampling again; cold start linked the
  previous session and chose `notSampled`. Shared-writer mode was rejected on every launch.
- He also reported 104 macOS and 104 simulator package tests, ten focused TSan tests, matching README
  coverage, Debug/Release simulator App Group tests, and unsigned device-target compilation passing.
- The UIKit probe passed eight launches per configuration on the simulator, and the macOS subset passed
  six. His local backend verifier found 37 logs/events, 25 spans and seven sessions; all eight negative
  mutations were rejected.

The first device attempt failed during share-sheet discovery after installation. A retry without
reinstallation passed; Ben also added the extension to Favorites. His results do **not** validate the
later retry/scroll fix or discovery without Favorites on a phone.

**Separate backend evidence:** Ben used an October 7 Faro checkout and Alloy 1.17.0, not the original
`ae334608c7c5352006626c4ac746cb5b9a937269` fixture with Alloy 1.16.1. His GitHub report does not include
the collector commit hash. The verifier was unchanged, with local Loki/Tempo ports forwarded to
13100/13200. Do not combine these into one backend/version claim. Neither run used hosted ingestion.

### Discovery follow-up verification on October 16, 2026

Environment: Xcode 27.0 (27A266a), iPhone 18 Pro Simulator / iOS 27.0 (24A434), arm64.

- Both UI tests passed in Debug and optimized Release, without whole-test retries. Release started
  from a fresh installation of the test app. The regression forces the first discovery attempt to
  reopen and uses an overflowing share row and the full Apps list, without changing Favorites.
- Each configuration produced 12 distinct host/extension PIDs across the two tests. Reopening retained
  one host manager: fresh starts still had no previous ID, reset phases sampled 51 times per role,
  and restores retained the saved snapshot with zero sampler calls. All shared-writer checks passed.
- All 104 macOS package tests passed again. The unsigned generic iOS Release build and Xcode Analyze
  completed, and Swift formatting, Ruby syntax and whitespace checks passed.
- No package implementation or dependency changed. The full simulator package suite, TSan and backend
  telemetry probe were not rerun for this harness-only fix; their earlier evidence remains dated above.
  There was no local physical device available to repeat Ben's signed-device test on this revision.

Commands follow the reproduction section below, with `build analyze` for the unsigned device target.
Logs and exported JSON attachments are retained in ignored `run-evidence-20261016-share-discovery/`.

### Compatibility follow-up verification on October 16, 2026

The probe manifest now declares Swift tools 6.2, matching its dependency. The package README and
source comments no longer describe iOS 13/14 support for this candidate. No session implementation,
project-generator logic or process-termination logic changed.

- Regenerated the Xcode probe with `xcodeproj` 1.27.0. Debug and Release built with fresh DerivedData
  on Xcode 27.0; the local package product resolved without an explicit product-level package reference.
- The iPhone 18 Pro Simulator / iOS 27.0 probe passed eight launches in each configuration. Each run
  captured 25 logs/events and 25 spans at local Alloy, including offline SIGKILL/replay and no duplicate replay.
- Before each SIGKILL, host `ps` and simulator `launchctl` identified the same running probe PID.
  The existing host kill command terminated that simulator process; it is not a separate guest PID.
- The macOS probe built with the updated manifest and passed its six-launch subset. All 104 macOS
  package tests passed with coverage enabled. Ruby/Node syntax and whitespace checks passed.
- SwiftFormat reported the same 44 pre-existing findings in the four comment-only Swift files;
  no formatting findings were added. No unrelated reformatting was applied.

These runs used Swift 6.4, Node 24 and the existing local Alloy 1.16.1, not the minimum Swift 6.2 compiler.
They did not rerun the App Group UI tests, physical device, TSan, iOS package suite or Faro/backend checks.
Evidence: `run-92e1cea1-038d-47fe-bdd7-033d415ad176/` (Debug),
`run-d8abe2eb-ab69-4e2b-884a-be8049f24b9a/` (Release),
`run-fb0cf651-2b45-4dba-a33e-52ba4cdbd4d4/` (macOS), and
`run-evidence-20261016-compatibility/` (build/test logs and the PID observer).

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

The signed App Group requirement has device evidence from Ben at `8fada4bc`, as recorded above.

1. Review/adopt the narrow Grafana integration and its iOS 15 / Swift tools 6.2 boundary with the package
   owner. Keep package extraction/release (#150) separate; do not silently modify its PR.
2. Reconcile #99, #57's gap matrix and the Mobile O11y guides with this evidence and the explicit MetricKit,
   metric and extension limitations. Shared issues/docs have **not** been changed in this task.

The full telemetry probe still has no physical-device run: `run.mjs` uses `simctl` and loopback services.
Minimum-iOS runtime, full 15-minute/four-hour waits, MetricKit attribution, hosted ingestion, product UI,
power-loss durability and released-package installation remain unverified. The updated discovery path
also needs a phone rerun without Favorites; Ben's previous pass is not evidence for that change.
#57 still has separate Android work; passing this candidate alone does not complete the cross-platform epic.

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

The UI test retries discovery for up to three sheet presentations within a 45-second discovery budget.
It scrolls the app row to reveal an off-screen extension or More cell and reopens the sheet if necessary.
Reopening reuses the request and host manager; it does not restart the session assertions. The host allows
90 seconds for the extension-ready handshake, while subsequent handshakes retain the 20-second timeout.
Discovery failures retain a screenshot and accessibility hierarchy. Use English system labels for this
UI harness. Do not use blanket test retries to hide a session or entitlement assertion failure.

The second UI test deliberately fills the real share row, asserts More is off-screen, and ignores the
first match to exercise the discovery retry. It closes the Apps list and sheet, reopens them, and selects
the extension through More. The same reset/restore/cold-start assertions detect an accidental extra
session manager or sampling call during reopening; OS registration delay itself is not simulated.

#### Physical-device signing and App Group provisioning

1. Use approved, unique test identifiers. From `app-group`, generate the project with
   `SESSION99_BUNDLE_PREFIX=<approved-bundle-id> SESSION99_APP_GROUP=<approved-group-id> ruby create-project.rb`.
   Configure signing **after** generation: rerunning the generator overwrites the generated project.
2. In the Apple Developer portal, select the Raintank team and register or locate the approved App Group
   under **Certificates, Identifiers & Profiles > Identifiers > App Groups**. Its identifier must exactly
   match `SESSION99_APP_GROUP`. Ask a team admin if your role cannot register it. See Apple's
   [registration steps](https://developer.apple.com/help/account/identifiers/register-an-app-group/).
3. Register or locate both App IDs: `<approved-bundle-id>` (host) and
   `<approved-bundle-id>.Session99Share` (extension). Enable App Groups and assign the same group to both.
   Merely enabling the capability is not enough if the selected groups list is empty.
4. Open `Generated/Session99Groups.xcodeproj` in Xcode. Under **Signing & Capabilities**, select the team
   and development signing for the host, extension and UI-test runner. For **both host and extension**,
   add App Groups if needed and check the approved group. Confirm it is selected for Debug and Release.
   See Apple's [Xcode setup](https://developer.apple.com/documentation/xcode/configuring-app-groups).
5. Connect, trust and unlock the test device, enable Developer Mode if prompted, and select it in Xcode.
   Let Xcode refresh development profiles after assigning the group. Resolve signing errors before
   testing; both profiles and signed entitlements must include the same App Group. The runner needs
   development signing, but it does not need the App Group capability.

The generator does not register identifiers or provision profiles. `xcodebuild -allowProvisioningUpdates`
is not a substitute for assigning the App Group: Ben found that it registered App IDs with the capability
but left their group selections empty. After completing setup, run:

```sh
xcodebuild -project Generated/Session99Groups.xcodeproj -scheme Session99Groups \
  -configuration Debug -destination "platform=iOS,id=$DEVICE_ID" \
  -resultBundlePath /tmp/session99-groups-device-debug.xcresult \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM_ID" test
```

Repeat with `Release` and a new result-bundle path. Keep one test running at a time. Record the tested
commit, device/OS, signing identities, matching entitlements and JSON result attachments. For discovery
validation, leave the extension out of Favorites and use a fresh installation of this disposable test app.
A simulator pass is not proof of device provisioning or App Group access.

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

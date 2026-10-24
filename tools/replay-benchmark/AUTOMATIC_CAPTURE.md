# Automatic captures for the Android demo

This uses the multipart MP4 library plus the timing/lifecycle fixes in
[library PR #3](https://github.com/grafana/hackathon-18-faro-android-replay/pull/3), tested at
`a9d677afb25fab5646a91644be7ec79c56eb5c98`. Use that revision or its verified successor from the PR;
an older library checkout will not include those fixes. The app changes build on
[QuickPizza PR #126](https://github.com/grafana/mobile-o11y-demo/pull/126), tested from
`2e2cb972` plus the automatic-capture and input-masking changes in this checkout. Tap
**Start replay** once on Home, Login, About or Debug. Navigation, scrolling, showing a handled error and the
registered loading/content states then request a capture after 500 ms without another change.
Movement of registered input or screen bounds restarts that delay, including expanding sections.
The existing **Capture replay** button remains available for manual diagnostics.

Only those four audited screens participate; Profile and Config remain excluded. Expanding Customize also triggers a capture;
arbitrary text changes and animation frames do not. The app sends static screen names and
visibility flags to the trigger policy, never credentials or field values.

**Stop replay** cancels pending and in-flight work. Backgrounding pauses capture; returning
resumes within the original two-minute run. Navigation, rotation, stop and later state changes
invalidate earlier work. Neither callbacks nor returning from the background start a new run
after the deadline. Starting again requires another explicit tap. There is no idle capture timer.

The SDK still owns the telemetry session. Its released session lookup records activity, so this
is a bounded foreground demo, not a claim that replay leaves session expiry unchanged. The
recorder keeps capture-time session/recording identity and handles session changes independently.

## Privacy and media

The demo defaults to `maskAllInputs=true`, `maskAllText=false`, `blockAllMedia=false`.
The app's colors, layout, images and normal labels stay visible. All six text inputs on the
supported screens register bounds explicitly (two Login fields and four Home customization
fields). The recommendation title is explicitly excluded because the backend may echo the
Custom name input there. Passwords and `grafanaNoCapture()` controls are always covered, even if input masking
is disabled. Platform status/navigation bars remain covered. This is a source-audited demo
integration, not automatic detection of arbitrary Compose inputs. Add registrations before
adding a new supported field or screen. Text/media-wide masking is not declared by this
geometry source: requesting either stricter option rejects capture instead of claiming coverage. The recorder rejects frames with the keyboard open,
uncertain geometry, overlapping navigation entries or a window that is no longer focused/eligible. Closing the keyboard schedules a
fresh attempt. Masking still happens before encoding on the device.

Each accepted frame currently becomes a five-second MP4 of that one masked image. This adds
automatic state capture; it does not introduce a continuous multi-frame video encoder. The
library fix preserves the actual capture timestamp rather than spacing all events five seconds
apart, contains file/codec failures and cleans up cancelled encodes before admitting another.

## Player integration

The tested player checkout builds on `yduartep/mobile-mp4-playback` at
`438bec5ead608900c0415c5d38d856af625ba822`, with the root-relative API proxy correction from
[player PR #430](https://github.com/grafana/grafana-sessionreplay-app/pull/430) head
`4097208689b5fd42ad70df5d8142d608e786bdc1` and the timing/availability fixes prepared for that PR.
It gives the session its own playback clock, holds the previous frame through gaps and selects
the newest capture when clips overlap. Seeking uses the same coverage, including independent
checkpoint groups, while keeping error/trace positions relative to the session start.

Fetch the completed app, library and player changes together; the app PR alone does not update
the other checkouts. The standalone upload smoke proves app capture, masking, multipart delivery
and decodable media. The separate real-stack validation below also checked storage/readback and
the Grafana session page. Do not infer persistence from a mock receiver acknowledgment.

## Verified local full-stack journey

The API 35 ARM64 emulator produced 14 automatically captured MP4s with no manual Capture clicks.
The populated Login fields and a Home input that moved during actual scrolling stayed masked.
Home and About retained their colors in decoded MP4s. Unsupported Config, the open keyboard,
backgrounding and Stop suppressed capture; returning to the foreground and rotation captured
again within the same run and SDK session. Ten seconds idle produced no additional capture.

The real backend returned 14 segments with all 28 uploaded Meta/video events, preserving their
ordering and timestamps. All 14 fetched MP4s matched their uploaded bytes and decoded, including
portrait and landscape clips. Full-file and range reads succeeded. The checkout error's exact
session, trace and span were found in Loki and Tempo.

The actual local Grafana mobile session page played the stored clips, held Home through the idle
gap with Skip inactivity disabled, sought to the error marker and backward to Home, and played
the rotated clips. The error became visible in its first captured frame 588 ms after the error
marker, reflecting the settling delay. Fullscreen was unavailable in browser automation; inline
playback was verified. This is local emulator and Grafana validation, not a cloud deployment or
physical-device claim.

Those results used backend [PR #1900](https://github.com/grafana/app-o11y-kwl-endpoint/pull/1900)
at `2051e402db82223e149d1454c4c94155e9a68f5b` and FEO
[PR #4267](https://github.com/grafana/app-o11y-kwl/pull/4267) at
`5df848e1d347778aae71f0ddc00a47dc6b248e8a`, with the player fixes described above. The test stack
used those pinned checkouts; it did not validate the full workbench bootstrap command. It was
stopped after verification. Session Narrator links are not covered by this run.

## CI dependency access

The replay library is not published to Maven. Set `FARO_REPLAY_DIR` or `-PfaroReplayDir` to an
authorized checkout for every Android build, including CI. QuickPizza is a public repository;
the hackathon replay library is private. The ordinary job token cannot check out that private
repository, and there is currently no configured, sanctioned cross-repository token grant for
this workflow. The required Android build check will remain blocked until that access is set up
and the workflow checks out the pinned library. Replay is not disabled to make the check pass,
and private library source is not copied into this public repository.

## Local validation

Run `automatic_smoke.py --help` for the disposable-emulator runner. It uses synthetic local
configuration, a loopback receiver and the supplied library checkout. The existing `smoke.py`
and five-minute comparison remain historical screenshot-format tools and are not the MP4
integration test.

The app's full JVM suite covers the scheduler's retained callbacks, coalescing, busy retries,
original deadline, stop/resume and reentrant state changes. The library's unit and emulator
tests cover timing, session attribution, physical capture ownership and encoder cleanup.
The instrumentation test waits for the exact checkout trace/span IDs and error text to reach
the receiver in both ordinary SDK trace and log exports before its process exits. This avoids
losing the last error to normal SDK disk batching. That wire check is not backend persistence;
a real-stack run still needs independent Loki/Tempo readback. Actual invocation, source
revisions and current results belong in the saved validation output.

The six `NativeExitCrashReporter` API lint errors are also fixed: the two private
API-30 helpers now declare the runtime requirement already enforced by their caller.
Debug lint reports zero errors; 41 warnings and two hints remain. All 52 app JVM tests and
debug/minified-release builds passed after this correction.

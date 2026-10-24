# Comparison from a common lossless source

This opt-in experiment follows up the WebP-to-video benchmark. It does not change the library,
the app's masking policy, the capture mode or the transport. Use a test emulator and the local
backend/configuration in [README](README.md). Do not run it against a real user's app or account.

## Inputs and workloads

`QuickPizzaFormatComparisonTest` with `losslessBenchmark=true` drives the same five-minute real
QuickPizza journey: Home, populated synthetic Login fields, customization, scrolling, handled
checkout error, both orientations, and idle periods. The test-only PixelCopy path uses the app's
existing mask geometry, checks it again after capture and paints solid masks before PNG encoding.
It bypasses the production lossy encoder and transport. The real SDK supplies session IDs and
timestamps on explicit test capture requests. The session getter still counts as activity.

`FairMotionComparisonTest` drives a separate synthetic Compose screen. Two populated fields stay
masked, public list items scroll, and generated bars animate on native vsync. It uses synthetic
session identity. Its phases are scrolling (15–99 seconds), animation (100–199) and both (200–299).
The one-second sampling cadence represents slideshow replay, not a smooth-video capture study.

Both source runs last 300 seconds with 300 fresh captures. Each capture saves the full-resolution
**already-masked** PNG and one common PNG normalized to an 800-pixel long edge with even dimensions.
Both candidates independently decode that exact normalized PNG. Neither codec consumes output
from the other, and neither gets a different resolution or timeline. Keep the original PNGs to
verify every masked pixel. Synthetic recording scopes split at 100 and 200 seconds; these are
benchmark boundaries, not a test of the production recorder's two-minute timer.

## Native encoding

`FairReplayEncoderTest` runs each candidate in a fresh instrumentation process. WebP qualities
25/30/60/85 and a lossless control use Android `Bitmap.compress`. Exact image reuse remains bounded
to 32 entries / 8 MiB of data-URI-equivalent bytes, scoped by session, recording, screen and size.
Every frame is encoded before reuse detection, so encoder CPU is not hidden by the deduplication.

H.264 uses Android MediaCodec with explicit VBR or CBR, 25/75/200/500 kbps targets, 1 fps and
sRGB transfer, BT.709 primaries/matrix and limited-range YUV. RGB-to-YUV conversion averages 2×2
chroma samples. The `srgb-` candidates use the AOSP platform value 2 for sRGB transfer and assert
that this codec returns the requested color configuration. That constant is not a named public
`MediaFormat` API; validate support before using this path on other devices. The returned bitstream
is independently checked for BT.709 primaries/matrix and IEC 61966-2-1 transfer.

The older candidates without that prefix used BT.601 / SDR transfer and remain diagnostic only:
Chrome displayed different brightness from the sRGB PNG source. They are excluded from the final
quality comparison. [AOSP color constants](https://android.googlesource.com/platform/frameworks/av/+/master/media/module/foundation/include/media/stagefright/foundation/ColorUtils.h)

Five-frame
clips are the baseline; one- versus five-second keyframe targets are compared separately. Longer
15/30-frame clips test both five-second and full-clip keyframe targets. Recording and dimension
changes always split clips. Actual capture timestamps and the last frame's hold duration survive.

Capture both requested and returned encoder settings. Android's [minimum video quality floor](https://developer.android.com/reference/android/media/MediaCodec#qualityFloor) can increase low
VBR targets; CBR is exempt from that behavior. The configured target is not the measured bitrate.
The decoder checks actual I/P frame placement rather than trusting the requested keyframe interval.

## Run and inspect

Use Python 3.12+ for safe archive extraction, NumPy, Pillow and FFmpeg. Build/install the app and
instrumentation APK with the local-only config first. Set `ADB` to the SDK's `platform-tools/adb`.
Use a fresh output directory and run names; the runner preserves completed logs and candidates.
Run these commands from the QuickPizza checkout. The default run names require a fresh test
emulator or fresh app data; an existing `fair-idle-300` or `fair-motion-300` is deliberately not
overwritten. The supplied viewer expects those two default source names.

```sh
python3 tools/replay-benchmark/fair_run.py /path/to/output --adb "$ADB" --stage sources
python3 tools/replay-benchmark/fair_run.py /path/to/output --adb "$ADB" --stage encode
python3 tools/replay-benchmark/fair_run.py /path/to/output --adb "$ADB" --stage export
python3 tools/replay-benchmark/fair_analyze.py /path/to/output/fair-idle-300 --ffmpeg /path/to/ffmpeg
python3 tools/replay-benchmark/fair_analyze.py /path/to/output/fair-motion-300 --ffmpeg /path/to/ffmpeg
python3 tools/replay-benchmark/fair_serve.py /path/to/output
```

Require `OK (1 test)` for every instrumentation invocation, not only adb exit status zero. A
10-second smoke capture exercises setup, not a substitute for the reported five-minute runs.
The runner uses the test emulator only; it does not open a remote connection or upload recordings.

The loopback viewer compares source, WebP and video, checks presented-frame timestamps after
forward/backward seeks, and plays across clip/rotation/recording boundaries. Its Save button
writes only `browser-checks.json` in the local output directory. Stop the viewer, backend and
owned emulator after validation. Export evidence before any connected-test cleanup uninstalls APKs.

## Quality and cost interpretation

The analyzer decodes every frame, checks identity, dimensions, timing, final hold duration, reuse
references, keyframes, and exact source mask pixels. Quality excludes gray masks plus a two-pixel
resampling margin. It reports visible RGB PSNR, non-overlapping 8×8 luminance block SSIM and
high-contrast achromatic edge PSNR. Block SSIM is not the Gaussian-window reference implementation;
edge PSNR alone does not prove text legibility. Four focused tests check the scoring behavior.

Inspect eight evenly spaced frames from each journey side by side. The optional macOS `ocr.swift`
compares text recognized in those source PNGs with each candidate. Recognition retention is a
diagnostic, not human perceptual equivalence. The report should show the whole quality/size curve;
do not compare a low-quality screenshot setting against a higher-quality video without saying so.
Visible temporal artifacts override a close numerical score. Inspect motion and text at native
resolution and during playback; reject a claimed quality match when the video leaves ghosting or
smears text, even if average PSNR, SSIM and sampled OCR fall within a narrow numerical band.

Encoding wall time, caller CPU, process CPU and sampled app PSS include PNG decode, codec setup,
color conversion, image reuse and file I/O. They exclude source collection and the separate codec
service's CPU/memory. Encoding happens after capture, not concurrently with a live journey. A fresh
process per candidate and reversed candidate order across journeys reduce some carryover, but
these remain individual emulator trials, not hardware, battery or jank results.

Payload totals include actual media files and compact playback manifests. These are experimental
asset/reference models, not the current Faro envelope, agreed upload API, headers, retries, storage
costs or Grafana session-panel playback. Clip buffering adds roughly its duration before upload;
local seek readiness does not measure remote download latency.

# Replay format comparison: common lossless source

This is the corrected benchmark, replacing the earlier exploratory 168 KB versus 872 KB comparison. The test results below belong to the source and library revisions in [provenance.json](provenance.json); packaging them for handoff does not rerun or revalidate a later revision.

**Recommendation: keep screenshots with exact image reuse for the hackathon.** The corrected five-second video baseline did not provide a size advantage at comparable measured quality on either journey. Low-bitrate longer clips were smaller on moving content, but visibly smeared text and graphics. This is a result for one emulator and these workloads, not a claim that screenshots are generally more efficient than video.

## What changed

Two fresh five-minute source runs captured 300 frames each. The idle-heavy run drives the actual QuickPizza app through Login with populated synthetic fields, Home, customization, scrolling, a handled error, rotation and idle periods. The other run uses a separate synthetic Compose screen with public scrolling text and continuously animated bars; two populated fields remain masked. The real app’s conservative mask policy was not relaxed.

PixelCopy output is masked before encoding. Full-resolution masked PNGs are retained. Each capture is then normalized once to an 800-pixel long edge (360×800 or 800×360); both encoders independently consume that same lossless PNG. Neither codec consumes the other’s output. Original capture timestamps, dimensions, session identity and recording boundaries are preserved. The test samples once per second; it compares slideshow replay, not smooth-video capture.

Image reuse is exact encoded-byte reuse, scoped to the session and recording, with screen name and dimensions in the key. The experiment uses a 32-entry / 8 MiB bounded cache and retains a timestamped reference for every captured frame. Every screenshot is encoded before the reuse check; this comparison does not claim capture or encoding CPU savings from skipping a frame.

The original color configuration also needed correction. sRGB screenshot values had been tagged as BT.601/SDR video, changing brightness in Chrome. Final `srgb-` candidates use BT.709 primaries/matrix, limited-range YUV and matching sRGB transfer. Both MediaCodec’s returned settings and the MP4’s color metadata were verified; the corrected browser rendering was inspected. Android’s sRGB transfer value is defined by [AOSP ColorUtils](https://android.googlesource.com/platform/frameworks/av/+/master/media/module/foundation/include/media/stagefright/foundation/ColorUtils.h), but lacks a named public MediaFormat constant. This test asserts that this codec supports it; it is not a production portability guarantee. Older color-mismatched trials remain separate diagnostic evidence and are excluded from the final comparison.

## Results at comparable measured quality

All sizes below use decimal KB/MB and include actual media plus compact playback manifests. They exclude the final upload API envelope, HTTP headers, retries and storage overhead.

- **Idle-heavy QuickPizza:** WebP Q85 with reuse was **255,654 bytes**; five-second H.264 VBR was **968,588 bytes**. Mean visible PSNR was 28.41 vs 28.62 dB, block SSIM 0.9970 vs 0.9969, and source-relative OCR similarity 99.86% for both. Screenshots stored 23 images for 300 capture timestamps. This workload masks about 93.3% of its area, including the scoring margin.
- **Scrolling and animation:** WebP Q60 with reuse was **4,402,271 bytes**; five-second H.264 CBR at a requested 200 kbps was **4,800,339 bytes**. Mean visible PSNR was 33.31 vs 32.71 dB, block SSIM 0.9907 vs 0.9921, and OCR similarity 97.55% vs 99.38%. Text remains readable in inspected samples, though edge artifacts differ. Screenshots stored 223 images for 300 timestamps. This workload masks about 10.7% of its area.
- **Smaller long video is a quality tradeoff:** Thirty-second CBR clips at a requested 25 kbps were **2,931,141 bytes**, versus **3,437,247 bytes** for WebP Q25. The video is about 14.7% smaller, and mean PSNR is close, but moving text and bars visibly smear. That pair is rejected as an equal-quality saving. See [source frame 299](samples/motion-source-299.png), [WebP Q25](samples/motion-webp-25-299.png), and [decoded long MP4 frame](samples/motion-video-cbr-25-30s-299.png).
- **Lossless control:** On the synthetic moving screen, lossless WebP was **5,262,661 bytes**, smaller than Q85’s 5,572,171 bytes. Simple UI content can behave differently from photographic footage; quality settings are not interchangeable across codecs.

The comparison uses the complete quality/size curve, not equal numeric quality settings. Approximate numerical pairs were screened within 1 dB mean visible PSNR, 0.005 block SSIM, 2 dB text-edge PSNR and 2 percentage points of OCR similarity. These are diagnostics, not proof of perceptual equivalence: the visually worse long-video pair is explicitly excluded despite close averages. Quality metrics exclude masked pixels and a two-pixel resampling margin. Block SSIM uses non-overlapping 8×8 luminance blocks, not the Gaussian-window reference implementation. OCR checks eight frames per journey against source-recognized text, not a perfect transcription. Actual decoded frames and browser rendering were also inspected.

## Encoding settings and cost

The final matrix contains 24 configurations per journey: WebP Q25/Q30/Q60/Q85/lossless, and 19 H.264 settings covering VBR/CBR, 25/75/200/500 kbps, one- versus five-second keyframes, and separate 15/30-second clips with five-second or full-clip keyframe spacing. Actual I/P frames were checked, rather than trusting the interval setting. [Android keyframe interval reference](https://developer.android.com/reference/android/media/MediaFormat#KEY_I_FRAME_INTERVAL).

For all four VBR targets, this emulator returned an effective configured target of **864,000 bps** and identical five-second payload sizes and decoded-quality scores for the same source. This is consistent with Android’s documented [VBR minimum quality floor](https://developer.android.com/reference/android/media/MediaCodec#qualityFloor). CBR targets were accepted, but measured output could still exceed low requested rates, particularly with frequent clip restarts. All reported payloads use measured bytes.

For the idle pair, screenshot encoding took **4.32 seconds** total with **190.0 MiB** peak app PSS, versus **7.55 seconds** and **235.9 MiB** for video. For the moving pair, screenshots took **5.52 seconds**, **5.45 seconds app CPU** and **203.5 MiB** peak PSS, versus **7.43 seconds**, **6.17 seconds app CPU** and **235.6 MiB** for video. Every frame is WebP-encoded before exact reuse detection, so deduplication does not hide screenshot encoding CPU.

Each configuration ran in a fresh instrumentation process, after source capture. Measurements include PNG decode, codec setup, conversion, reuse lookup, file I/O and sampling overhead. CPU/PSS exclude the separate codec service. These are single emulator trials using the software `c2.android.avc.encoder`, not statistically stable hardware, battery, thermal or jank results. Common PNG source collection is an experimental cost, not production recorder overhead.

## Playback and validation

The local Chrome viewer checks forward/backward seeking, actual presented-frame timestamps, final-frame hold, and playback across clip, recording and rotation boundaries. Five-, fifteen- and thirty-second clips were all locally seekable. Longer clips can delay upload by their duration; local loopback seek latency does not measure remote fetch cost. Final counts and timing samples are in [browser checks](browser-checks.json) and [browser summary](browser-summary.json).

The two five-minute source runs and all 48 final native configuration trials passed. Every full-resolution source mask pixel was checked. All 14,400 final candidate frames were decoded and checked for quality, dimensions, identity, ordering, PTS and final hold duration. The source sequence digests are in [compact-results.json](compact-results.json); exact source, tool and APK hashes are recorded in [provenance.json](provenance.json).

Android debug app/instrumentation builds passed, as did 29 app JVM tests and four analyzer tests. The viewer’s JavaScript syntax was checked. The recorded app lint run reported six existing API-level errors in unchanged `NativeExitCrashReporter.kt`; the historical test counts and lint result are retained in [validation.json](validation.json). No production library or transport code was changed by this experiment.

## Reproduce and inspect

Use the [common-source benchmark guide](../../FAIR_COMPARISON.md) for the runner, native encoders, analyzer, OCR diagnostic and local viewer. This small evidence package contains the [48 final cases](compact-results.json), recorded [browser checks](browser-checks.json), [quality assessment](quality-audit.json) and eight unmodified PNG samples. Full five-minute source sequences, candidate media and the original logs are retained in the local benchmark output, not included here. Re-running the guide produces its own `fair-idle-300` and `fair-motion-300` directories for the viewer. This package by itself is not a playable recording. Earlier video candidates without the `srgb-` prefix were excluded because their color metadata was wrong.

Keep screenshot capture for the hackathon. The file-reference image reuse measured here is an experimental path; it is not wired into the existing base64 rrweb upload flow. Keep that upload flow until the replacement file API is ready, then verify reuse against it. This comparison is complete without Yahima’s APIs; it does not prove storage, authorization, ingestion or playback in Grafana’s mobile session panel. A future video decision should be tested on physical devices at the intended capture cadence and acceptable visible quality.

## Inspect the actual captures

These are byte-for-byte copies of masked, normalized emulator captures and decoded comparison frames. The source images are lossless PNGs at the common 800-pixel long edge, not screenshots of a chart or mockup. Open each image at native size.

- Idle QuickPizza frame 0: [source](samples/idle-source-0.png), [WebP Q85](samples/idle-webp-85-0.png), [five-second H.264 VBR](samples/idle-video-vbr-75-5s-0.png). Most of this real app view is intentionally masked.
- Synthetic scrolling/animation frame 299: [source](samples/motion-source-299.png), [WebP Q60](samples/motion-webp-60-299.png), [five-second H.264 CBR at requested 200 kbps](samples/motion-video-cbr-200-5s-299.png). Public test text and bars remain visible; the populated fields are covered.
- Quality tradeoff at that same frame: [WebP Q25](samples/motion-webp-25-299.png) and [thirty-second H.264 at requested 25 kbps](samples/motion-video-cbr-25-30s-299.png). The smaller video smears text and moving bars.

[Package manifest](package-manifest.json) records the source of each copied file and its SHA-256. It also records the figure and browser-count cross-check performed when this package was prepared.

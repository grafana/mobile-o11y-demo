"""Compare each native candidate against its common masked PNG, never against another codec."""
import argparse
import hashlib
import json
import math
import re
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image


def read(path):
    return json.loads(path.read_text())


def pixels(path):
    with Image.open(path) as image:
        return np.asarray(image.convert("RGB"), dtype=np.float32)


def visible(frame):
    w, h = frame["width"], frame["height"]
    mask = np.ones((h, w), dtype=bool)
    sx, sy = w / frame["originalWidth"], h / frame["originalHeight"]
    for left, top, right, bottom in frame["originalMasks"]:
        # Exclude resampling/codec mask edges as well as flat masked areas from quality scoring.
        x0, y0 = max(0, math.floor(left*sx)-2), max(0, math.floor(top*sy)-2)
        x1, y1 = min(w, math.ceil(right*sx)+2), min(h, math.ceil(bottom*sy)+2)
        mask[y0:y1, x0:x1] = False
    return mask


def psnr(mse):
    return 99.0 if mse < 1e-12 else 10 * math.log10(255**2 / mse)


def quality(reference, decoded, mask):
    assert reference.shape == decoded.shape and mask.any()
    delta = (reference-decoded)**2
    mse = float(delta[mask].mean())
    a = reference @ np.array([.299, .587, .114], dtype=np.float32)
    b = decoded @ np.array([.299, .587, .114], dtype=np.float32)
    # Non-overlapping 8x8 luminance SSIM, using only entirely visible blocks.
    h, w = (a.shape[0]//8)*8, (a.shape[1]//8)*8
    def blocks(x):
        return x[:h, :w].reshape(h//8, 8, w//8, 8).transpose(0, 2, 1, 3).reshape(-1, 64)
    aa, bb, valid = blocks(a), blocks(b), blocks(mask).all(axis=1)
    ma, mb = aa.mean(axis=1), bb.mean(axis=1)
    da, db = aa-ma[:, None], bb-mb[:, None]
    score = ((2*ma*mb+6.5025)*(2*(da*db).mean(axis=1)+58.5225) /
             ((ma**2+mb**2+6.5025)*((da**2).mean(axis=1)+(db**2).mean(axis=1)+58.5225)))
    gx, gy = np.gradient(a)
    edges = (np.hypot(gx, gy) > 24) & mask & ((reference.max(axis=2)-reference.min(axis=2)) < 35)
    return {"visiblePsnrDb": psnr(mse), "visibleMse": mse,
            "visibleBlockSsim": float(score[valid].mean()),
            "textEdgePsnrDb": psnr(float(delta[edges].mean())) if edges.any() else None,
            "visiblePixels": int(mask.sum()), "textEdgePixels": int(edges.sum())}


def stats(values):
    a = np.array(values, dtype=float)
    return {"min": float(a.min()), "median": float(np.median(a)), "mean": float(a.mean()),
            "p05": float(np.percentile(a, 5)), "p95": float(np.percentile(a, 95)), "max": float(a.max())}


def validate_source(root, source):
    frames = source["frames"]
    assert all(a["timestamp"] < b["timestamp"] for a, b in zip(frames, frames[1:]))
    assert source["end"] > frames[-1]["timestamp"]
    hashes, covered = [], []
    for frame in frames:
        original = pixels(root / frame["original"])
        assert original.shape[:2] == (frame["originalHeight"], frame["originalWidth"])
        for x0, y0, x1, y1 in frame["originalMasks"]:
            assert np.all(original[y0:y1, x0:x1] == 94), "Unmasked pixels in source mask"
        image = pixels(root / frame["file"])
        assert image.shape[:2] == (frame["height"], frame["width"])
        hashes.append(hashlib.sha256((root / frame["file"]).read_bytes()).hexdigest())
        covered.append(1-float(visible(frame).mean()))
    return {"frames": len(frames), "durationSeconds": (source["end"]-frames[0]["timestamp"])/1000,
            "captureElapsedMs": source["journey"]["elapsedMs"], "sourceHashes": hashes,
            "maskedFractionWithTwoPixelMargin": stats(covered),
            "captureAndPngWallMs": stats([f["captureAndPngWallMs"] for f in frames]),
            "everyOriginalMaskPixelVerified": True}


def analyze(root, ffmpeg, candidates=None):
    source = read(root / "source.json")
    frames = source["frames"]
    source_hash = hashlib.sha256((root / "source.json").read_bytes()).hexdigest()
    source_check = validate_source(root, source)
    inspection = root / "inspection"
    inspection.mkdir(exist_ok=True)
    picks = sorted(set(min(len(frames)-1, round(i*(len(frames)-1)/7)) for i in range(8)))
    for i in picks:
        Image.open(root / frames[i]["file"]).save(inspection / f"source-{i}.png")
    rows = []
    per_frame = {}
    if candidates:
        previous = read(root / "analysis.json")
        assert previous["sourceSha256"] == source_hash
        assert previous["source"]["sourceHashes"] == source_check["sourceHashes"]
        rows = [r for r in previous["candidates"] if r["candidate"] not in candidates]
        per_frame = read(root / "quality-by-frame.json")
    for result_file in sorted(root.glob("*/result.json")):
        if candidates and result_file.parent.name not in candidates:
            continue
        result = read(result_file)
        assert result["sourceSha256"] == source_hash
        candidate = result["candidate"]
        path = result_file.parent
        scores = []
        keyframes = []
        files = set()
        if result["kind"] == "images":
            confirmed = set()
            assert len(result["frames"]) == len(frames)
            for i, (sample, frame) in enumerate(zip(result["frames"], frames)):
                assert all(sample[k] == frame[k] for k in ["session", "recording", "timestamp", "width", "height", "screen"])
                key = (sample["session"], sample["recording"], sample["file"])
                if sample["reused"]:
                    assert key in confirmed
                else:
                    confirmed.add(key)
                files.add(sample["file"])
                decoded = pixels(path / sample["file"])
                scores.append(quality(pixels(root / frame["file"]), decoded, visible(frame)))
                if i in picks:
                    Image.fromarray(decoded.astype(np.uint8)).save(inspection / f"{candidate}-{i}.png")
            manifest = {"format": "images", "end": source["end"], "frames": result["frames"]}
        else:
            decoded_count = 0
            for clip in result["clips"]:
                assert clip["firstFrame"] == decoded_count
                files.add(clip["file"])
                decoded = subprocess.run([ffmpeg, "-v", "info", "-i", str(path / clip["file"]),
                    "-vf", "showinfo", "-vsync", "0", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                    capture_output=True, check=True, timeout=120)
                diagnostics = decoded.stderr.decode()
                if candidate.startswith("srgb-"):
                    assert "bt709/bt709/iec61966-2-1" in diagnostics, "Incorrect video color metadata"
                times = re.findall(r"pts_time:([\d.]+).*?duration_time:([\d.]+).*?iskey:(\d).*?type:(\w)", diagnostics)
                assert len(times) == clip["frameCount"], diagnostics[-2000:]
                assert abs(sum(map(float, times[-1][:2])) - (clip["end"]-clip["start"])/1000) < .002
                raw = np.frombuffer(decoded.stdout, dtype=np.uint8).reshape(-1, clip["height"], clip["width"], 3)
                assert len(raw) == clip["frameCount"]
                key_indexes = [i for i, item in enumerate(times) if item[2] == "1"]
                assert key_indexes == clip["keyframeIndexes"] and key_indexes[0] == 0
                keyframes.append({"file": clip["file"], "indexes": key_indexes, "frameTypes": [t[3] for t in times]})
                for local, image in enumerate(raw):
                    i = decoded_count + local
                    frame = frames[i]
                    assert all(frame[k] == clip[k] for k in ["session", "recording", "width", "height"])
                    assert abs(float(times[local][0])*1000 - (frame["timestamp"]-clip["start"])) < 1.1
                    assert clip["presentationTimesUs"][local] == (frame["timestamp"]-clip["start"])*1000
                    scores.append(quality(pixels(root / frame["file"]), image.astype(np.float32), visible(frame)))
                    if i in picks:
                        Image.fromarray(image).save(inspection / f"{candidate}-{i}.png")
                decoded_count += len(raw)
            assert decoded_count == len(frames)
            manifest = {"format": "video", "end": source["end"], "clips": [
                {k: clip[k] for k in ["file", "start", "end", "width", "height", "session", "recording"]}
                for clip in result["clips"]]}
        manifest_bytes = json.dumps(manifest, separators=(",", ":")).encode()
        (path / "playback.json").write_bytes(manifest_bytes)
        media_bytes = sum((path / name).stat().st_size for name in files)
        row = {"candidate": candidate, "kind": result["kind"], "files": len(files), "mediaBytes": media_bytes,
               "metadataBytes": len(manifest_bytes), "totalBytes": media_bytes + len(manifest_bytes),
               "meanMediaBitrateBps": media_bytes*8/source_check["durationSeconds"],
               **{k: result[k] for k in ["encodeWallMs", "encodeCallerCpuMs", "encodeProcessCpuMs", "pssStartKb", "peakPssKb"]},
               "sampledPssGrowthKb": result["peakPssKb"]-result["pssStartKb"],
               "quality": {k: stats([s[k] for s in scores if s[k] is not None])
                           for k in ["visiblePsnrDb", "visibleBlockSsim", "textEdgePsnrDb"]}}
        if result["kind"] == "video":
            row["keyframes"] = keyframes
            row["codecConfiguration"] = result["clips"][0]["configuration"]
            row["colorMetadataVerified"] = candidate.startswith("srgb-")
            row["clipEncodeWallMs"] = stats([c["encodeWallMs"] for c in result["clips"]])
        else:
            row["allImageBytesWithoutReuse"] = result["allImageBytesWithoutReuse"]
            row["reusedFrames"] = sum(f["reused"] for f in result["frames"])
            row["frameEncodeWallMs"] = stats([t["wallMs"] for t in result["timings"]])
        rows.append(row)
        per_frame[candidate] = scores
        print(root.name, candidate, row["totalBytes"], round(row["quality"]["visiblePsnrDb"]["mean"], 2), flush=True)
    assert rows, "No candidate results found"
    report = {"source": source_check, "journey": source["journey"]["kind"], "sourceSha256": source_hash,
              "candidates": rows, "inspectionIndexes": picks,
              "notes": ["Every codec reads the identical lossless, already-masked PNG sequence.",
                        "Both use the same one-time 800px downscale, dimensions, timestamps and identity.",
                        "Visible-region metrics exclude masks; text-edge PSNR is not a legibility verdict.",
                        "8x8 block SSIM is not the Gaussian-window reference SSIM implementation.",
                        "Payloads are media plus local playback manifests, not a finalized API envelope.",
                        "CPU excludes the separate codec service; PSS is sampled app-process memory.",
                        "Source capture saves PNGs for the experiment; its overhead is not production overhead."]}
    (root / "analysis.json").write_text(json.dumps(report, indent=2))
    (root / "quality-by-frame.json").write_text(json.dumps(per_frame))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--ffmpeg", required=True)
    parser.add_argument("--candidates", nargs="+", help="Append only these new candidates to an existing analysis")
    args = parser.parse_args()
    analyze(args.directory.resolve(), args.ffmpeg, args.candidates)

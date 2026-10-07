"""Run isolated emulator trials. Requires prebuilt APKs and the loopback QuickPizza backend."""
import argparse
import json
import subprocess
import tarfile
from pathlib import Path

LEGACY_CANDIDATES = ["webp-25", "webp-30", "webp-60", "webp-85", "webp-lossless",
              "vbr-25-g5-c5", "vbr-75-g5-c5", "vbr-200-g5-c5", "vbr-500-g5-c5",
              "cbr-25-g5-c5", "cbr-75-g5-c5", "cbr-200-g5-c5", "cbr-500-g5-c5",
              "vbr-75-g1-c5", "vbr-75-g5-c15", "vbr-75-g15-c15",
              "vbr-75-g5-c30", "vbr-75-g30-c30",
              "cbr-25-g5-c15", "cbr-25-g15-c15", "cbr-25-g5-c30", "cbr-25-g30-c30",
              "cbr-75-g15-c15", "cbr-75-g30-c30"]
CANDIDATES = [c if c.startswith("webp-") else "srgb-" + c for c in LEGACY_CANDIDATES]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--adb", required=True)
    parser.add_argument("--serial", default="emulator-5554")
    parser.add_argument("--stage", choices=["sources", "encode", "export"], required=True)
    parser.add_argument("--runs", nargs="+", default=["idle-300", "motion-300"])
    parser.add_argument("--candidates", nargs="+", default=CANDIDATES)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    adb = [args.adb, "-s", args.serial]
    assert args.serial.startswith("emulator-"), "This harness is scoped to a test emulator"
    for run in args.runs:
        assert run.replace("-", "").isalnum()
        if args.stage == "sources":
            seconds = int(run.rsplit("-", 1)[1])
            motion = run.startswith("motion-")
            test = "FairMotionComparisonTest" if motion else "QuickPizzaFormatComparisonTest"
            commands = [(run, ["-e", "class", "com.grafana.quickpizza.features.debug." + test,
                              "-e", "fairBenchmark" if motion else "quickPizzaBenchmark", "true",
                              "-e", "losslessBenchmark", "true", "-e", "benchmarkRun", run,
                              "-e", "benchmarkSeconds", str(seconds)])]
        elif args.stage == "encode":
            commands = []
            # Reverse the order for the other journey to expose order-dependent warming.
            for candidate in (args.candidates if run.startswith("idle") else list(reversed(args.candidates))):
                assert candidate in CANDIDATES + LEGACY_CANDIDATES
                commands.append((run + "-" + candidate, ["-e", "class",
                    "com.grafana.quickpizza.features.debug.FairReplayEncoderTest", "-e", "fairBenchmark", "true",
                    "-e", "benchmarkRun", run, "-e", "candidate", candidate]))
        else:
            archive = args.output / (run + ".tar")
            with archive.open("wb") as stream:
                subprocess.run(adb + ["exec-out", "run-as", "com.grafana.quickpizza.android", "tar", "-cf", "-",
                                      "-C", "files", "fair-" + run], stdout=stream, check=True, timeout=120)
            with tarfile.open(archive) as tar:
                tar.extractall(args.output, filter="data")
            print("Exported " + run, flush=True)
            continue
        for name, options in commands:
            logfile = args.output / (name + ".log")
            if logfile.exists():
                raise RuntimeError(f"Preserve earlier evidence: {logfile} already exists")
            command = adb + ["shell", "am", "instrument", "-w", "-r"] + options + [
                "com.grafana.quickpizza.android.test/androidx.test.runner.AndroidJUnitRunner"]
            print("Running " + name, flush=True)
            with logfile.open("w") as stream:
                result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, timeout=900)
            assert result.returncode == 0 and "OK (1 test)" in logfile.read_text(), logfile.read_text()[-4000:]
            print("Passed " + name, flush=True)
    (args.output / (args.stage + "-commands.json")).write_text(json.dumps(vars(args), default=str, indent=2))


if __name__ == "__main__":
    main()

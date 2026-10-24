"""Build and exercise the local replay handoff on a disposable Android emulator."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tarfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
APP = "com.grafana.quickpizza.android"
TEST = APP + ".test/androidx.test.runner.AndroidJUnitRunner"


def run(command, **kwargs):
    return subprocess.run([str(x) for x in command], check=True, **kwargs)


def read(command):
    return run(command, capture_output=True, text=True, timeout=30).stdout.strip()


def wait_ready(process, url):
    for _ in range(100):
        if process.poll() is not None:
            raise RuntimeError("Local server exited; inspect its log")
        try:
            with urllib.request.urlopen(url, timeout=1) as response:
                if response.status == 200:
                    return
        except OSError:
            time.sleep(.1)
    raise RuntimeError("Local server did not become ready: " + url)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="new directory outside the checkout")
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--serial", required=True, help="disposable emulator serial, never a physical device")
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--reset-test-app", action="store_true", help="allow clearing this emulator's existing QuickPizza demo data")
    args = parser.parse_args()
    if not args.serial.startswith("emulator-"):
        parser.error("use a disposable test emulator")
    library = args.library.resolve()
    output = args.output.resolve()
    if not (library / "replay/build.gradle.kts").is_file():
        parser.error("--library must point to the replay library checkout")
    if output == ROOT or ROOT in output.parents or output.exists():
        parser.error("use a new output directory outside the checkout; existing evidence is preserved")
    for tool in (args.adb, "go", "java"):
        if not shutil.which(tool):
            parser.error("required command is unavailable: " + tool)
    adb = [args.adb, "-s", args.serial]
    if read(adb + ["shell", "getprop", "sys.boot_completed"]) != "1":
        parser.error("wait for the emulator to finish booting")
    if read(adb + ["shell", "getprop", "ro.kernel.qemu"]) != "1":
        parser.error("only an Android emulator is supported")
    if int(read(adb + ["shell", "getprop", "ro.build.version.sdk"])) < 30:
        parser.error("this smoke test requires API 30 or newer")
    installed_result = subprocess.run(adb + ["shell", "pm", "path", APP], capture_output=True, text=True, timeout=30)
    if installed_result.returncode not in (0, 1):
        raise RuntimeError("Unable to query installed demo package")
    installed = installed_result.stdout.strip()
    if installed and not args.reset_test_app:
        parser.error("QuickPizza is already installed; use a fresh emulator or --reset-test-app to clear its demo data")
    if "tcp:18002" in read(adb + ["reverse", "--list"]):
        parser.error("port 18002 already has an adb reverse mapping; preserve it and use a clean emulator")
    for port in (18002, 18003):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", port))
    output.mkdir(parents=True)
    config = output / "android-config.json"
    config.write_text(json.dumps({
        "BASE_URL": "http://127.0.0.1:18002",
        "REPLAY_ENDPOINT": "http://127.0.0.1:18002/collect/quickpizza-benchmark",
        "OTLP_ENDPOINT": "http://127.0.0.1:18002/otlp/quickpizza-benchmark",
        "OTLP_INSTANCE_ID": "", "OTLP_API_KEY": ""
    }, indent=2) + "\n")
    env = dict(os.environ, QUICKPIZZA_ANDROID_CONFIG_FILE=str(config))
    processes, streams = [], []
    reversed_port = False
    app_started = False
    try:
        print("Building local backend and Android debug/test APKs", flush=True)
        # Match Makefile build-go: Go embeds this directory even for the API-only backend.
        frontend = ROOT / "pkg/web/build/index.html"
        if not frontend.exists():
            frontend.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / "pkg/web/dev.html", frontend)
        with (output / "build.log").open("w") as log:
            run(["go", "build", "-o", output / "backend", "tools/replay-benchmark/backend.go"],
                cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=600)
            run(["./gradlew", "-PfaroReplayDir=" + str(library), ":app:assembleDebug",
                 ":app:assembleDebugAndroidTest", ":app:testDebugUnitTest"],
                cwd=ROOT / "Mobiles/android", env=env, stdout=log, stderr=subprocess.STDOUT, timeout=1200)
        print("Starting loopback backend and test sink", flush=True)
        for name, command, url in [
            ("backend", [output / "backend", output / "pizza.db"], "http://127.0.0.1:18003/healthz"),
            ("receiver", [sys.executable, ROOT / "tools/replay-benchmark/receiver.py", output / "receiver"],
             "http://127.0.0.1:18002/_benchmark/latest")
        ]:
            stream = (output / (name + ".log")).open("w")
            streams.append(stream)
            process = subprocess.Popen([str(x) for x in command], cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
            processes.append(process)
            wait_ready(process, url)
        reversed_port = True
        run(adb + ["reverse", "tcp:18002", "tcp:18002"], timeout=30)
        apks = [ROOT / "Mobiles/android/app/build/outputs/apk" / path for path in
                ("debug/app-debug.apk", "androidTest/debug/app-debug-androidTest.apk")]
        for apk in apks:
            run(adb + ["install", "-r", apk], timeout=120)
        if args.reset_test_app and installed:
            if read(adb + ["shell", "pm", "clear", APP]) != "Success":
                raise RuntimeError("Unable to clear the selected test app")
        print("Running the ten-capture journey: navigation, synthetic inputs, error, scroll and rotation", flush=True)
        app_started = True
        command = adb + ["shell", "am", "instrument", "-w", "-r", "-e", "class",
            "com.grafana.quickpizza.features.debug.QuickPizzaFormatComparisonTest",
            "-e", "quickPizzaBenchmark", "true", "-e", "benchmarkSeconds", "10",
            "-e", "benchmarkRun", "handoff-smoke", TEST]
        with (output / "instrumentation.log").open("w") as log:
            run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        if not re.search(r"^OK \(1 test\)\s*$", (output / "instrumentation.log").read_text(), re.MULTILINE):
            raise RuntimeError("Instrumentation did not report OK (1 test); inspect instrumentation.log")
        archive = output / "app-evidence.tar"
        with archive.open("wb") as stream:
            run(adb + ["exec-out", "run-as", APP, "tar", "-cf", "-", "-C", "files",
                       "format-comparison-handoff-smoke"], stdout=stream, timeout=30)
        with tarfile.open(archive) as tar:
            with tar.extractfile("format-comparison-handoff-smoke/results.json") as stream:
                result = json.load(stream)
        receipt = json.loads((output / "receiver/handoff-smoke/receipt-summary.json").read_text())
        frames = result["samples"]
        if result["frames"] != 10 or receipt["frames"] != 10:
            raise RuntimeError("Expected ten locally received masked frames")
        if {f["screen"] for f in frames} != {"Home", "Login"}:
            raise RuntimeError("Both demo screens must be present")
        if not any(f["width"] > f["height"] for f in frames):
            raise RuntimeError("Expected a landscape capture")
        summary = {
            "kind": "local handoff smoke, not Grafana storage or a five-minute comparison",
            "frames": len(frames), "screens": sorted({f["screen"] for f in frames}),
            "sessions": len({f["session"] for f in frames}), "faroRequestBodyBytes": receipt["bodyBytes"],
            "androidApi": read(adb + ["shell", "getprop", "ro.build.version.sdk"]),
            "device": read(adb + ["shell", "getprop", "ro.product.model"]),
            "apkSha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in apks}
        }
        (output / "smoke-result.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps(summary, indent=2), flush=True)
    finally:
        had_error = sys.exc_info()[0] is not None
        errors = cleanup(adb, app_started, reversed_port, processes, streams)
        if errors:
            print("Cleanup needs attention: " + "; ".join(errors), file=sys.stderr)
            if not had_error:
                raise RuntimeError("Smoke completed, but cleanup did not finish")


def cleanup(adb, app_started, reversed_port, processes, streams):
    errors = []
    commands = []
    if app_started:
        commands.append(adb + ["shell", "am", "force-stop", APP])
    if reversed_port:
        commands.append(adb + ["reverse", "--remove", "tcp:18002"])
    for command in commands:
        try:
            subprocess.run(command, timeout=30, check=True)
        except (OSError, subprocess.SubprocessError) as error:
            errors.append(str(error))
    for process in reversed(processes):
        try:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        except (OSError, subprocess.SubprocessError) as error:
            errors.append(str(error))
    for stream in streams:
        try:
            stream.close()
        except OSError as error:
            errors.append(str(error))
    return errors


if __name__ == "__main__":
    main()

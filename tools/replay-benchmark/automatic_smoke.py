"""Build and verify automatic settled-state MP4 captures on a disposable emulator."""
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

from smoke import APP, ROOT, TEST, cleanup, read, run, wait_ready


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="new output directory outside the checkout")
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--reset-test-app", action="store_true")
    args = parser.parse_args()
    if not args.serial.startswith("emulator-"):
        parser.error("select a disposable test emulator")
    library, output = args.library.resolve(), args.output.resolve()
    if not (library / "replay/build.gradle.kts").is_file():
        parser.error("--library must identify the replay checkout")
    if output.exists() or output == ROOT or ROOT in output.parents:
        parser.error("preserve previous evidence; use a new directory outside the checkout")
    for tool in (args.adb, "go", "java"):
        if not shutil.which(tool):
            parser.error("required tool unavailable: " + tool)
    adb = [args.adb, "-s", args.serial]
    if read(adb + ["shell", "getprop", "ro.kernel.qemu"]) != "1" or read(adb + ["shell", "getprop", "sys.boot_completed"]) != "1":
        parser.error("a fully booted emulator is required")
    if int(read(adb + ["shell", "getprop", "ro.build.version.sdk"])) < 30:
        parser.error("this integration test requires API 30 or newer")
    installed_result = subprocess.run(adb + ["shell", "pm", "path", APP], capture_output=True, text=True, timeout=30)
    if installed_result.returncode not in (0, 1):
        raise RuntimeError("Unable to query installed QuickPizza")
    installed = bool(installed_result.stdout.strip())
    if installed and not args.reset_test_app:
        parser.error("use a fresh emulator or --reset-test-app to clear only the demo package")
    if "tcp:18002" in read(adb + ["reverse", "--list"]):
        parser.error("preserve the existing adb reverse mapping; use a clean emulator")
    for port in (18002, 18003):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", port))
    output.mkdir(parents=True)
    config = output / "android-config.json"
    config.write_text(json.dumps({"BASE_URL": "http://127.0.0.1:18002",
        "OTLP_ENDPOINT": "http://127.0.0.1:18002/otlp/automatic-smoke",
        "OTLP_INSTANCE_ID": "", "OTLP_API_KEY": ""}, indent=2) + "\n")
    env = {key: value for key, value in os.environ.items() if not key.startswith("FARO_SOURCEMAP_")}
    env["QUICKPIZZA_ANDROID_CONFIG_FILE"] = str(config)
    processes, streams = [], []
    reversed_port = app_started = False
    try:
        print("Building emulator app and instrumentation APKs", flush=True)
        frontend = ROOT / "pkg/web/build/index.html"
        if not frontend.exists():
            frontend.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / "pkg/web/dev.html", frontend)
        with (output / "build.log").open("w") as log:
            run(["go", "build", "-o", output / "backend", "tools/replay-benchmark/backend.go"],
                cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=600)
            run(["./gradlew", "-PfaroReplayDir=" + str(library), ":app:assembleDebug", ":app:assembleDebugAndroidTest", ":app:testDebugUnitTest"],
                cwd=ROOT / "Mobiles/android", env=env, stdout=log, stderr=subprocess.STDOUT, timeout=1200)
        for name, command, url in [
            ("backend", [output / "backend", output / "pizza.db"], "http://127.0.0.1:18003/healthz"),
            ("receiver", [sys.executable, ROOT / "tools/replay-benchmark/automatic_receiver.py", output / "receiver"],
             "http://127.0.0.1:18002/_automatic/receipts")
        ]:
            stream = (output / (name + ".log")).open("w")
            streams.append(stream)
            process = subprocess.Popen([str(item) for item in command], cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
            processes.append(process)
            wait_ready(process, url)
        reversed_port = True
        run(adb + ["reverse", "tcp:18002", "tcp:18002"], timeout=30)
        apks = [ROOT / "Mobiles/android/app/build/outputs/apk" / path for path in
                ("debug/app-debug.apk", "androidTest/debug/app-debug-androidTest.apk")]
        for apk in apks:
            run(adb + ["install", "-r", apk], timeout=120)
        if installed and args.reset_test_app and read(adb + ["shell", "pm", "clear", APP]) != "Success":
            raise RuntimeError("Failed to clear selected demo package")
        app_started = True
        print("Testing navigation, populated masks, scrolling, error, rotation, background and stop", flush=True)
        with (output / "instrumentation.log").open("w") as log:
            run(adb + ["shell", "am", "instrument", "-w", "-r", "-e", "class",
                "com.grafana.quickpizza.features.debug.AutomaticReplayCaptureTest", "-e", "automaticReplaySmoke", "true", TEST],
                stdout=log, stderr=subprocess.STDOUT, timeout=240)
        if not re.search(r"^OK \(1 test\)\s*$", (output / "instrumentation.log").read_text(), re.MULTILINE):
            raise RuntimeError("Instrumentation did not report OK (1 test); inspect instrumentation.log")
        report = json.loads(read(adb + ["exec-out", "run-as", APP, "cat", "files/automatic-replay-smoke.json"]))
        for index in sorted({step["receiptIndex"] for step in report["steps"]}):
            with (output / ("masked-frame-%04d.png" % index)).open("wb") as image:
                run(adb + ["exec-out", "run-as", APP, "cat", f"files/automatic-frame-{index}.png"], stdout=image, timeout=30)
        with (output / "emulator-visible-error.png").open("wb") as image:
            run(adb + ["exec-out", "run-as", APP, "cat", "files/automatic-emulator-error.png"], stdout=image, timeout=30)
        report["environment"] = {"serial": args.serial,
            "api": read(adb + ["shell", "getprop", "ro.build.version.sdk"]),
            "device": read(adb + ["shell", "getprop", "ro.product.model"])}
        report["apkSha256"] = {apk.name: hashlib.sha256(apk.read_bytes()).hexdigest() for apk in apks}
        (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2), flush=True)
    finally:
        had_error = sys.exc_info()[0] is not None
        errors = cleanup(adb, app_started, reversed_port, processes, streams)
        if errors:
            print("Cleanup needs attention: " + "; ".join(errors), file=sys.stderr)
            if not had_error:
                raise RuntimeError("Test finished but cleanup did not complete")


if __name__ == "__main__":
    main()

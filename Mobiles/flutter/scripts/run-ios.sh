#!/bin/bash

# Script to run Flutter app on iOS simulator
# Make sure iOS simulator is available

cd "$(dirname "$0")/.."

# ============================================
# Config file check
# ============================================
CONFIG_FILE="$(python3 ../telemetry/flutter-config.py)" || exit 1

echo "✅ Using config from $CONFIG_FILE"

# ============================================
# iOS device detection
# ============================================
# Use simctl so a connected physical iPhone is never mistaken for a simulator.
IOS_DEVICE=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
devices=[d for group in json.load(sys.stdin)["devices"].values() for d in group
         if d.get("isAvailable") and "iPhone" in d["name"]]
devices.sort(key=lambda d: d["state"] != "Booted")
if not devices: sys.exit("No available iPhone simulator. Install one in Xcode.")
print(devices[0]["udid"])
') || exit 1
xcrun simctl boot "$IOS_DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$IOS_DEVICE" -b || exit 1
DEVELOPER_DIR_PATH=$(xcode-select -p)
if [ -d "$DEVELOPER_DIR_PATH/Applications/Simulator.app" ]; then
    open "$DEVELOPER_DIR_PATH/Applications/Simulator.app"
else
    open "$DEVELOPER_DIR_PATH/../Applications/DeviceHub.app"
fi

echo "Running Flutter app on iOS simulator: $IOS_DEVICE"
flutter run -d "$IOS_DEVICE" --dart-define-from-file="$CONFIG_FILE"

#!/usr/bin/env bash
set -euo pipefail

# Open the iOS Simulator UI for the selected Xcode.
#
# Usage:
#   Mobiles/scripts/open-simulator.sh            # open the Simulator UI
#   Mobiles/scripts/open-simulator.sh <udid>     # boot <udid> (if needed) and show it
#
# Xcode 27 replaces Simulator.app with DeviceHub.app, one level above Developer/.
# Resolve from the selected Xcode so a second installed Xcode's app isn't opened.

UDID="${1:-}"

if [[ -n "$UDID" ]]; then
    if ! xcrun simctl list devices | grep -q "($UDID)"; then
        echo "Unknown simulator UDID: $UDID (see: xcrun simctl list devices available)" >&2
        exit 1
    fi
    # Booting an already-booted device fails; that's fine.
    xcrun simctl boot "$UDID" 2>/dev/null || true
fi

XCODE_DEVELOPER_DIR="$(xcode-select -p)"
if [[ -d "$XCODE_DEVELOPER_DIR/Applications/Simulator.app" ]]; then
    if [[ -n "$UDID" ]]; then
        open "$XCODE_DEVELOPER_DIR/Applications/Simulator.app" --args -CurrentDeviceUDID "$UDID"
    else
        open "$XCODE_DEVELOPER_DIR/Applications/Simulator.app"
    fi
elif [[ -d "$XCODE_DEVELOPER_DIR/../Applications/DeviceHub.app" ]]; then
    if [[ -n "$UDID" ]]; then
        open "devices://device/open?id=$UDID"
    else
        open "$XCODE_DEVELOPER_DIR/../Applications/DeviceHub.app"
    fi
else
    echo "Neither Simulator.app nor DeviceHub.app found under $XCODE_DEVELOPER_DIR" >&2
    exit 1
fi

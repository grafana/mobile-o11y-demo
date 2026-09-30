#!/usr/bin/env bash
set -euo pipefail

SCHEME="QuickPizzaIos"
PROJECT="QuickPizzaIos.xcodeproj"
BUNDLE_ID="com.grafana.QuickPizzaIos"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEVICE=""
STREAM_LOGS=1

usage() {
    echo "Usage: $0 [--device <simulator name>] [--no-logs]"
    echo ""
    echo "Options:"
    echo "  --device <name>   Simulator device name (e.g. 'iPhone 17 Pro')"
    echo "                    Defaults to a booted iPhone simulator, else the first available one."
    echo "  --no-logs         Exit after launch instead of streaming logs."
    echo ""
    echo "Examples:"
    echo "  $0"
    echo "  $0 --device 'iPhone 17 Pro'"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE="$2"; shift 2 ;;
        --no-logs) STREAM_LOGS=0; shift ;;
        --help|-h) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Prints "<udid>\t<name>\t<state>". Prefers a booted match so an open simulator is reused.
resolve_device() {
    xcrun simctl list devices available -j 2>/dev/null \
        | python3 -c "
import json, sys
wanted = sys.argv[1]
data = json.load(sys.stdin)
matches = [
    d
    for runtime in sorted(data.get('devices', {}).keys(), reverse=True)
    for d in data['devices'][runtime]
    if d.get('isAvailable')
    and (d.get('name') == wanted if wanted else 'iPhone' in d.get('name', ''))
]
if not matches:
    sys.exit(1)
d = next((d for d in matches if d.get('state') == 'Booted'), matches[0])
print(d['udid'], d['name'], d.get('state', 'Unknown'), sep='\t')
" "$1"
}

if [[ -z "$DEVICE" ]]; then
    echo "==> Auto-detecting simulator..."
fi
RESOLVED=$(resolve_device "$DEVICE") || {
    echo "ERROR: No available simulator found${DEVICE:+ named '$DEVICE'}."
    exit 1
}
IFS=$'\t' read -r UDID DEVICE BOOT_STATE <<< "$RESOLVED"
echo "==> Using simulator: $DEVICE ($UDID)"

echo "==> Building $SCHEME for simulator..."
CONFIG_ARGS=()
if [[ -n "${QUICKPIZZA_IOS_CONFIG_FILE:-}" ]]; then
    CONFIG_ARGS=(-xcconfig "$QUICKPIZZA_IOS_CONFIG_FILE")
fi
# bash 3.2 treats an empty "${arr[@]}" as unbound under set -u.
xcodebuild ${CONFIG_ARGS[@]+"${CONFIG_ARGS[@]}"} \
    -project "$PROJECT_DIR/$PROJECT" \
    -scheme "$SCHEME" \
    -destination "id=$UDID" \
    -derivedDataPath "$PROJECT_DIR/DerivedData" \
    build 2>&1 | tail -20

APP_PATH=$(find "$PROJECT_DIR/DerivedData/Build/Products" -name "*.app" -type d | head -1)
if [[ -z "$APP_PATH" ]]; then
    echo "ERROR: Could not find .app bundle in DerivedData."
    exit 1
fi
echo "==> Found app: $APP_PATH"

if [[ "$BOOT_STATE" != "Booted" ]]; then
    echo "==> Booting simulator '$DEVICE'..."
    xcrun simctl boot "$UDID" 2>/dev/null || true
    # Resolve from the selected Xcode so a second installed Xcode's app isn't opened.
    # Xcode 27 replaces Simulator.app with DeviceHub.app, one level above Developer/.
    XCODE_DEVELOPER_DIR="$(xcode-select -p)"
    if [[ -d "$XCODE_DEVELOPER_DIR/Applications/Simulator.app" ]]; then
        open "$XCODE_DEVELOPER_DIR/Applications/Simulator.app" --args -CurrentDeviceUDID "$UDID" || true
    elif [[ -d "$XCODE_DEVELOPER_DIR/../Applications/DeviceHub.app" ]]; then
        open "devices://device/open?id=$UDID" || true
    fi
    sleep 2
else
    echo "==> Simulator '$DEVICE' already booted."
fi

echo "==> Installing app..."
xcrun simctl install "$UDID" "$APP_PATH"

echo "==> Launching app..."
xcrun simctl launch "$UDID" "$BUNDLE_ID"

if [[ "$STREAM_LOGS" -eq 0 ]]; then
    exit 0
fi

echo "==> Streaming logs (Ctrl+C to stop)..."
echo "    (Showing logs from subsystem: $BUNDLE_ID)"
xcrun simctl spawn "$UDID" log stream \
    --predicate "subsystem == \"$BUNDLE_ID\"" \
    --level debug \
    --style compact

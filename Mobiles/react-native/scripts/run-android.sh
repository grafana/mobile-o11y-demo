#!/bin/bash
set -euo pipefail

# Run React Native on Android. Starts an emulator when none is connected.
#
# Usage:
#   ./scripts/run-android.sh                 # debug install (yarn android)
#   ./scripts/run-android.sh --emulator-only # boot emulator only (E2E / CI)

cd "$(dirname "$0")/.."

EMULATOR_ONLY=0
AVD_CLI=""

usage() {
  cat <<'USAGE'
Run the React Native QuickPizza app on Android.

  ./scripts/run-android.sh
  ./scripts/run-android.sh --emulator-only

Options:
  --emulator-only   Start/wait for an emulator only; do not run yarn android
  --avd <name>      AVD to launch when several exist (or set ANDROID_AVD)
  -h, --help        Show this help
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --emulator-only)
      EMULATOR_ONLY=1
      shift
      ;;
    --avd)
      AVD_CLI="${2:-}"
      [[ -n "$AVD_CLI" ]] || { echo "❌ --avd requires a name (see: emulator -list-avds)" >&2; exit 1; }
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1 (try --help)" >&2
      exit 1
      ;;
  esac
done

resolve_android_sdk() {
  if [ -n "${ANDROID_SDK_ROOT:-}" ] && [ -d "${ANDROID_SDK_ROOT}/emulator" ]; then
    printf '%s' "$ANDROID_SDK_ROOT"
  elif [ -n "${ANDROID_HOME:-}" ] && [ -d "${ANDROID_HOME}/emulator" ]; then
    printf '%s' "$ANDROID_HOME"
  elif [ -d "$HOME/Library/Android/sdk/emulator" ]; then
    printf '%s' "$HOME/Library/Android/sdk"
  else
    printf ''
  fi
}

has_android_device() {
  command -v adb >/dev/null 2>&1 || return 1
  adb devices 2>/dev/null | awk 'NR>1 && $2=="device" { found=1 } END { exit !found }'
}

adb_lists_emulator() {
  command -v adb >/dev/null 2>&1 || return 1
  adb devices 2>/dev/null | awk 'NR>1 && $1 ~ /^emulator-/ { found=1 } END { exit !found }'
}

emulator_process_running() {
  pgrep -f 'qemu-system|/emulator/emulator.*-avd' >/dev/null 2>&1
}

wait_for_adb_device() {
  local attempts="${1:-120}"
  local i=1

  while [ "$i" -le "$attempts" ]; do
    if has_android_device; then
      return 0
    fi
    if [ $((i % 10)) -eq 0 ]; then
      echo "Still waiting for adb device... ($i/${attempts}s)"
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

wait_for_android_boot() {
  local attempts="${1:-120}"
  local i=1
  local boot

  adb wait-for-device

  while [ "$i" -le "$attempts" ]; do
    boot="$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')"
    if [ "$boot" = "1" ]; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done

  echo "❌ Timed out waiting for Android boot (sys.boot_completed)." >&2
  echo "   Restart the emulator, then run this script again." >&2
  exit 1
}

wait_for_existing_emulator() {
  echo "Emulator already running; waiting for adb (not launching a second instance)..."

  if wait_for_adb_device 120; then
    echo "✅ Emulator ready in adb"
    wait_for_android_boot
    adb devices -l
    return 0
  fi

  echo "❌ Emulator is running but adb never reported device state." >&2
  echo "   Restart the emulator (cold boot in Android Studio), then run this script again." >&2
  adb devices -l >&2 || true
  exit 1
}

choose_avd() {
  local emu="$1"
  local chosen="" count=0 first="" line=""

  if [ -n "$AVD_CLI" ]; then
    printf '%s' "$AVD_CLI"
    return 0
  fi
  if [ -n "${ANDROID_AVD:-}" ]; then
    printf '%s' "$ANDROID_AVD"
    return 0
  fi

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    count=$((count + 1))
    [ "$count" -eq 1 ] && first="$line"
  done <<EOF
$("$emu" -list-avds 2>/dev/null || true)
EOF

  if [ "$count" -eq 0 ]; then
    echo "❌ No AVDs found. Create one in Android Studio Device Manager." >&2
    return 1
  elif [ "$count" -eq 1 ]; then
    printf '%s' "$first"
    return 0
  fi

  echo "❌ Multiple AVDs; pass --avd <name> or set ANDROID_AVD:" >&2
  "$emu" -list-avds 2>/dev/null || true
  return 1
}

ensure_android_emulator() {
  if has_android_device; then
    echo "✅ Android device/emulator already connected"
    wait_for_android_boot
    adb devices -l
    return 0
  fi

  if adb_lists_emulator || emulator_process_running; then
    wait_for_existing_emulator
    return 0
  fi

  local sdk emu chosen
  sdk="$(resolve_android_sdk)"
  if [ -z "$sdk" ]; then
    echo "❌ Android SDK not found. Set ANDROID_SDK_ROOT or ANDROID_HOME." >&2
    exit 1
  fi

  emu="$sdk/emulator/emulator"
  if [ ! -x "$emu" ]; then
    echo "❌ Emulator binary not found at: $emu" >&2
    exit 1
  fi

  export PATH="$sdk/platform-tools:$sdk/emulator:$PATH"
  chosen="$(choose_avd "$emu")" || exit 1

  if ! "$emu" -list-avds 2>/dev/null | grep -Fxq "$chosen"; then
    echo "❌ AVD not found: $chosen" >&2
    "$emu" -list-avds 2>/dev/null || true
    exit 1
  fi

  echo "No Android device found. Launching emulator: $chosen"
  nohup "$emu" -avd "$chosen" -no-snapshot-load >/tmp/quickpizza-emulator.log 2>&1 &
  echo "Emulator starting (log: /tmp/quickpizza-emulator.log) ..."

  local i=1
  local max_wait=120
  while [ "$i" -le "$max_wait" ]; do
    if has_android_device; then
      echo "✅ Emulator ready"
      wait_for_android_boot
      adb devices -l
      return 0
    fi
    if [ $((i % 10)) -eq 0 ]; then
      echo "Still waiting for emulator... ($i/${max_wait}s)"
    fi
    sleep 1
    i=$((i + 1))
  done

  echo "❌ Timed out waiting for emulator to appear in adb devices" >&2
  exit 1
}

ensure_android_emulator

if [ "$EMULATOR_ONLY" -eq 1 ]; then
  exit 0
fi

# ============================================
# Config file check (config.json, same as Flutter)
# ============================================
CONFIG_FILE="config.json"
CONFIG_EXAMPLE="config.json.example"

if [ ! -f "$CONFIG_FILE" ]; then
  echo ""
  echo "⚠️  WARNING: $CONFIG_FILE not found!"
  echo ""

  if [ -f "$CONFIG_EXAMPLE" ]; then
    echo "Creating $CONFIG_FILE from $CONFIG_EXAMPLE..."
    cp "$CONFIG_EXAMPLE" "$CONFIG_FILE"
    echo ""
    echo "📝 Please edit $CONFIG_FILE with your actual values:"
    echo "   - FARO_COLLECTOR_URL: Your Grafana Faro collector URL"
    echo "   - BASE_URL: Backend API URL (optional, has platform defaults)"
    echo "   - PORT: Backend port (optional, defaults to 3333)"
    echo ""
    echo "Then run this script again."
    exit 1
  else
    echo "❌ ERROR: $CONFIG_EXAMPLE not found!"
    exit 1
  fi
fi

echo "✅ Using config from $CONFIG_FILE"
echo ""
echo "Running React Native app on Android..."
echo "Make sure Metro is running (yarn start) in another terminal, or run: yarn android"
yarn android

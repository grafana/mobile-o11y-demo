#!/usr/bin/env bash
# Shared Android emulator bootstrap for all QuickPizza mobile demos.
#
# Starts or waits for an adb-ready emulator. Used by React Native, native Android,
# Flutter (via local RUM stack), and E2E scripts — not tied to a single SDK app.
#
# Usage:
#   ./Mobiles/scripts/ensure-android-emulator.sh
#   ./Mobiles/scripts/ensure-android-emulator.sh --avd Pixel_8_API_35
#   ANDROID_AVD=Pixel_8_API_35 ./Mobiles/scripts/ensure-android-emulator.sh
set -euo pipefail

AVD_CLI=""
ANDROID_SDK=""
ADB_SERIAL=""

usage() {
  cat <<'USAGE'
Ensure an Android emulator or device is connected and booted (adb-ready).

  ./Mobiles/scripts/ensure-android-emulator.sh
  ./Mobiles/scripts/ensure-android-emulator.sh --avd Pixel_8_API_35

Options:
  --avd <name>   AVD to launch when several exist (or set ANDROID_AVD)
  -h, --help     Show this help
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
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
  elif [ -d "$HOME/Android/Sdk/emulator" ]; then
    printf '%s' "$HOME/Android/Sdk"
  else
    printf ''
  fi
}

bootstrap_android_tools() {
  local sdk
  sdk="$(resolve_android_sdk)"
  if [ -n "$sdk" ]; then
    ANDROID_SDK="$sdk"
    export PATH="$sdk/platform-tools:$sdk/emulator:$PATH"
  fi
  command -v adb >/dev/null 2>&1 || {
    echo "❌ adb not found. Set ANDROID_SDK_ROOT/ANDROID_HOME or install Android platform-tools." >&2
    exit 1
  }
}

require_android_sdk() {
  if [ -z "$ANDROID_SDK" ]; then
    echo "❌ Android SDK not found. Set ANDROID_SDK_ROOT or ANDROID_HOME." >&2
    exit 1
  fi
}

run_adb() {
  if [ -n "$ADB_SERIAL" ]; then
    adb -s "$ADB_SERIAL" "$@"
  else
    adb "$@"
  fi
}

# Prefer an emulator-* serial when several adb devices are connected.
pick_adb_serial() {
  local serial state emulator_serial fallback_serial=""

  ADB_SERIAL=""
  while read -r serial state; do
    [ -z "$serial" ] && continue
    [ "$state" = "device" ] || continue
    if [[ "$serial" == emulator-* ]]; then
      emulator_serial="$serial"
      break
    fi
    [ -z "$fallback_serial" ] && fallback_serial="$serial"
  done < <(adb devices 2>/dev/null | awk 'NR>1 && NF>=2 {print $1, $2}')

  if [ -n "$emulator_serial" ]; then
    ADB_SERIAL="$emulator_serial"
    return 0
  fi
  if [ -n "$fallback_serial" ]; then
    ADB_SERIAL="$fallback_serial"
    return 0
  fi
  return 1
}

has_android_device() {
  pick_adb_serial
}

adb_lists_emulator() {
  adb devices 2>/dev/null | awk 'NR>1 && $1 ~ /^emulator-/ && $2=="device" { found=1 } END { exit !found }'
}

emulator_process_running() {
  pgrep -f 'qemu-system|/emulator/emulator.*-avd' >/dev/null 2>&1
}

wait_for_adb_device() {
  local attempts="${1:-120}"
  local i=1

  while [ "$i" -le "$attempts" ]; do
    if pick_adb_serial; then
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

  pick_adb_serial || {
    echo "❌ No adb device available for boot check." >&2
    exit 1
  }

  run_adb wait-for-device

  while [ "$i" -le "$attempts" ]; do
    boot="$(run_adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')"
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
    echo "✅ Emulator ready in adb (${ADB_SERIAL:-default})"
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
    echo "✅ Android device/emulator already connected (${ADB_SERIAL})"
    wait_for_android_boot
    adb devices -l
    return 0
  fi

  if adb_lists_emulator || emulator_process_running; then
    wait_for_existing_emulator
    return 0
  fi

  require_android_sdk

  local emu chosen
  emu="$ANDROID_SDK/emulator/emulator"
  if [ ! -x "$emu" ]; then
    echo "❌ Emulator binary not found at: $emu" >&2
    exit 1
  fi

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
    if pick_adb_serial; then
      echo "✅ Emulator ready (${ADB_SERIAL})"
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

bootstrap_android_tools
ensure_android_emulator

#!/usr/bin/env bash
set -euo pipefail

# Run React Native on Android. Starts an emulator when none is connected.
#
# Usage:
#   ./scripts/run-android.sh                 # debug install (yarn android)
#   ./scripts/run-android.sh --emulator-only # boot emulator only (E2E / CI)
#
# Emulator bootstrap is shared with other mobile demos:
#   ../../scripts/ensure-android-emulator.sh

cd "$(dirname "$0")/.."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_EMULATOR_SCRIPT="${SCRIPT_DIR}/../../scripts/ensure-android-emulator.sh"

EMULATOR_ONLY=0
FORWARD_ARGS=()

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
      FORWARD_ARGS+=(--avd "${2:-}")
      [[ -n "${2:-}" ]] || { echo "❌ --avd requires a name (see: emulator -list-avds)" >&2; exit 1; }
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

[[ -x "$SHARED_EMULATOR_SCRIPT" ]] || {
  echo "❌ Missing shared emulator script: ${SHARED_EMULATOR_SCRIPT}" >&2
  exit 1
}

bash "$SHARED_EMULATOR_SCRIPT" "${FORWARD_ARGS[@]}"

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

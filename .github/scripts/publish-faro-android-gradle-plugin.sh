#!/usr/bin/env bash
# Publish com.grafana.faro.android-symbols to ~/.m2 for CI until the plugin is on
# the Gradle Plugin Portal. Remove this script and workflow steps after v0.1.0+ is published.
set -euo pipefail

PLUGIN_DIR="${1:-.faro-android-gradle-plugin}"
VERSION="${FARO_ANDROID_GRADLE_PLUGIN_VERSION:-0.1.0}"

if [[ ! -f "${PLUGIN_DIR}/build.gradle.kts" ]]; then
  echo "Missing Faro Android Gradle plugin checkout at ${PLUGIN_DIR}" >&2
  exit 1
fi

if ! command -v gradle >/dev/null 2>&1; then
  echo "gradle is not on PATH; run gradle/actions/setup-gradle before this script" >&2
  exit 1
fi

echo "Publishing com.grafana.faro.android-symbols ${VERSION} to Maven Local from ${PLUGIN_DIR}"
(
  cd "${PLUGIN_DIR}"
  gradle publishToMavenLocal --no-daemon --stacktrace -Pversion="${VERSION}"
)

echo "Maven Local plugin artifacts:"
ls -la "${HOME}/.m2/repository/com/grafana/faro/" 2>/dev/null || true

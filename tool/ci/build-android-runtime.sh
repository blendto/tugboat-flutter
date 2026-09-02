#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
android="$root/platforms/android"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/sdk/android}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
if [[ ! -f "$android/local.properties" ]]; then
  printf 'sdk.dir=%s\n' "$ANDROID_HOME" >"$android/local.properties"
fi
cd "$android"
./gradlew :capture-runtime:test :capture-runtime-test:test :capture-runtime:assembleRelease :capture-runtime:publishAllPublicationsToLocalCaptureRepository
./gradlew :sample:assembleDebug

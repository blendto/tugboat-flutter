#!/usr/bin/env bash
# Builds the Android capture-runtime AAR from this repo and publishes it to
# the gitignored .local-maven, which the Flutter example resolves it from.
# Rerun after changing platforms/android/capture-runtime. Needs the NDK and
# CMake versions listed in AGENTS.md.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root/platforms/android"
./gradlew :capture-runtime:publishAllPublicationsToLocalCaptureRepository "$@"
version="$(sed -n 's/^VERSION_NAME=//p' gradle.properties)"
ls "$root/.local-maven/com/gettugboat/sdk/capture-runtime/$version/capture-runtime-$version.aar"

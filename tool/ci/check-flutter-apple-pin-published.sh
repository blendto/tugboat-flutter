#!/usr/bin/env bash
# When the Flutter plugin pins TugboatCaptureRuntime, that version must be on trunk.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
pin="$(bash tool/ci/flutter-apple-runtime-pin.sh)"
if [[ -z "$pin" ]]; then
  echo "Flutter plugin does not pin TugboatCaptureRuntime; skipping trunk check."
  exit 0
fi
if bash tool/ci/cocoapods-pod-has-version.sh "$pin"; then
  echo "CocoaPods trunk has TugboatCaptureRuntime ${pin}."
  exit 0
fi
echo "::error::Flutter plugin pins TugboatCaptureRuntime ${pin}, but that version is not on CocoaPods trunk yet."
exit 1

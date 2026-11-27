#!/usr/bin/env bash
# Build the Swift host (`Tugboat`) and run the package's XCTests on an iOS
# simulator. Needs Xcode. The simulator is the first available iPhone on the
# newest installed iOS runtime (`apple-simulator-udid.sh`); set
# TUGBOAT_SIMULATOR_ID to pin one.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

swift build --target Tugboat

udid="$(bash tool/ci/apple-simulator-udid.sh)"
echo "Simulator: $udid"

xcodebuild test \
  -scheme TugboatCaptureRuntime-Package \
  -destination "platform=iOS Simulator,id=$udid" \
  "$@"

#!/usr/bin/env bash
# Build the Swift host (`Tugboat`) and run the package's XCTests on an iOS
# simulator. Needs Xcode. The simulator is the first available iPhone on the
# newest installed iOS runtime (`apple-simulator-udid.sh`); set
# TUGBOAT_SIMULATOR_ID to pin one.
#
# Usage: test-apple-host.sh [--runtime-only] [xcodebuild args...]
#   --runtime-only  what the Flutter SDK uses: skip `swift build --target
#                   Tugboat` and run only TugboatCaptureRuntimeTests. Used for
#                   `device-report` PRs. Without it, every test target runs.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

runtime_only=0
if [[ "${1:-}" == "--runtime-only" ]]; then
  runtime_only=1
  shift
fi

if [[ "$runtime_only" == 0 ]]; then
  swift build --target Tugboat
fi

udid="$(bash tool/ci/apple-simulator-udid.sh)"
echo "Simulator: $udid"

only=()
if [[ "$runtime_only" == 1 ]]; then
  only=(-only-testing:TugboatCaptureRuntimeTests)
fi

set -x
xcodebuild test \
  -scheme TugboatCaptureRuntime-Package \
  -destination "platform=iOS Simulator,id=$udid" \
  ${only[@]+"${only[@]}"} \
  "$@"

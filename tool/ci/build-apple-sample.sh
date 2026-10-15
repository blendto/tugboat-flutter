#!/usr/bin/env bash
# Generate the SwiftUI sample's Xcode project with XcodeGen and build it for
# an iOS simulator (no signing). Needs Xcode; installs XcodeGen with Homebrew
# when it is missing. `XCODEBUILD_ACTION=test` runs the sample's XCUITests
# instead (`test-apple-sample-ui.sh`). Extra arguments go to xcodebuild.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
sample="$root/platforms/apple/Samples/TugboatSwiftUISample"
action="${XCODEBUILD_ACTION:-build}"

if ! command -v xcodegen >/dev/null 2>&1; then
  brew install xcodegen
fi
(cd "$sample" && xcodegen generate --spec project.yml)

udid="$(bash "$root/tool/ci/apple-simulator-udid.sh")"
echo "Simulator: $udid"
if [ "$action" = test ]; then
  # Boot first: a cold boot inside the first app launch times out on CI.
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b
fi

xcodebuild "$action" \
  -project "$sample/TugboatSwiftUISample.xcodeproj" \
  -scheme TugboatSwiftUISample \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$sample/build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  "$@"

#!/usr/bin/env bash
# Generate the SwiftUI sample's Xcode project with XcodeGen and build it for
# an iOS simulator (no signing). Needs Xcode; installs XcodeGen with Homebrew
# when it is missing. Extra arguments go to xcodebuild.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
sample="$root/platforms/apple/Samples/TugboatSwiftUISample"

if ! command -v xcodegen >/dev/null 2>&1; then
  brew install xcodegen
fi
(cd "$sample" && xcodegen generate --spec project.yml)

udid="$(bash "$root/tool/ci/apple-simulator-udid.sh")"
echo "Simulator: $udid"

xcodebuild build \
  -project "$sample/TugboatSwiftUISample.xcodeproj" \
  -scheme TugboatSwiftUISample \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$sample/build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  "$@"

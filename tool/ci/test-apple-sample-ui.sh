#!/usr/bin/env bash
# Run the SwiftUI sample's XCUITests (`TugboatSwiftUISampleUITests`) on an
# iOS simulator: `build-apple-sample.sh` with the `test` action. Extra
# arguments go to xcodebuild.
set -euo pipefail
XCODEBUILD_ACTION=test exec bash "$(dirname "$0")/build-apple-sample.sh" "$@"

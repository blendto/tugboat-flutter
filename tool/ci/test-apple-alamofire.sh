#!/usr/bin/env bash
# Build the optional `TugboatAlamofire` package (its own Package.swift, which
# depends on the root package by path and on Alamofire) and run its XCTests
# on an iOS simulator. Needs Xcode and network access to fetch Alamofire.
# Set TUGBOAT_SIMULATOR_ID to pin a simulator. Extra arguments go to
# xcodebuild.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
package="$root/platforms/apple/TugboatAlamofire"
cd "$package"

swift package resolve
echo "Resolved:"
swift package show-dependencies

# A package with one library product gets a scheme of that name; with more,
# Xcode adds `<name>-Package`, which runs every test target.
scheme="$(xcodebuild -list -json | python3 -c '
import json, sys
schemes = json.load(sys.stdin)["workspace"]["schemes"]
print("TugboatAlamofire-Package" if "TugboatAlamofire-Package" in schemes else "TugboatAlamofire")
')"
echo "Scheme: $scheme"

udid="$(bash "$root/tool/ci/apple-simulator-udid.sh")"
echo "Simulator: $udid"

xcodebuild test \
  -scheme "$scheme" \
  -destination "platform=iOS Simulator,id=$udid" \
  "$@"

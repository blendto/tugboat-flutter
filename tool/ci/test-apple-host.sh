#!/usr/bin/env bash
# Build the Swift host (`Tugboat`) and run the package's XCTests on an iOS
# simulator. Needs Xcode. The simulator is the first available iPhone on the
# newest installed iOS runtime, so a runner image change does not break it;
# set TUGBOAT_SIMULATOR_ID to pin one.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

swift build --target Tugboat

udid="${TUGBOAT_SIMULATOR_ID:-}"
if [[ -z "$udid" ]]; then
  udid="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
def version(runtime):
    return [int(part) for part in runtime.split("iOS-")[1].split("-")]
for runtime in sorted((r for r in devices if ".iOS-" in r), key=version, reverse=True):
    for device in devices[runtime]:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            print(device["udid"])
            sys.exit(0)
sys.exit("no available iPhone simulator")
')"
fi
echo "Simulator: $udid"

xcodebuild test \
  -scheme TugboatCaptureRuntime-Package \
  -destination "platform=iOS Simulator,id=$udid" \
  "$@"

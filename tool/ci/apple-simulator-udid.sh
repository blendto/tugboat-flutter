#!/usr/bin/env bash
# Print the UDID of the first available iPhone simulator on the newest
# installed iOS runtime (so a runner image change does not break CI), or
# TUGBOAT_SIMULATOR_ID when set. Needs Xcode.
set -euo pipefail
if [[ -n "${TUGBOAT_SIMULATOR_ID:-}" ]]; then
  echo "$TUGBOAT_SIMULATOR_ID"
  exit 0
fi
xcrun simctl list devices available -j | python3 -c '
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
'

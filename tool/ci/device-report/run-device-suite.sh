#!/usr/bin/env bash
# Runs the Flutter SDK device suite on one emulator or simulator:
#   1. device_checklist_test.dart via flutter drive -> device_checklist.json
#   2. capture_profile_test.dart via flutter drive, once per screenshot
#      backend (2 rounds of the script) -> profile_<backend>.json
# capture_smoke_test.dart is not run here: the checklist covers the same
# features row by row, and each app launch costs a build. The smoke test
# still runs on the host in the package tests.
# and collects JSON, metadata and logs into OUT_DIR for render-report.py.
#
# Usage: run-device-suite.sh <android|ios> <device-id> <out-dir>
#
# A checklist row that fails is a result, not a script failure. The script
# exits non-zero only when the harness produced no usable checklist or
# default-backend profile.
set -uo pipefail

platform="$1"
device="$2"
out="$3"

root="$(cd "$(dirname "$0")/../../.." && pwd)"
example="$root/sdks/flutter/packages/tugboat/example"
logs="$out/logs"
mkdir -p "$out" "$logs"
cd "$example" || exit 2

checklist_min_rows=13
status=0
declare -a notes=()

note() {
  echo "::notice::$*"
  notes+=("$*")
}

# On iOS, flutter finds the app's Dart VM service by reading the simulator
# log. On the first launch after boot it has missed that line (the app
# printed it) and waited until the time limit, about 6 minutes per run.
# A run that has waited this long without the URL is stopped and retried.
vm_service_wait=75

# Runs a command with a wall-clock limit (perl alarm), shows its output and
# keeps it in a log. On iOS it also stops a run stuck waiting for the VM
# service URL (see vm_service_wait).
bounded() {
  local limit="$1" log="$2"
  shift 2
  : > "$log"
  perl -e 'alarm shift; exec @ARGV' "$limit" "$@" > "$log" 2>&1 &
  local pid=$!
  tail -n +1 -f "$log" &
  local tail_pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 5
    [[ "$platform" == ios && "$waited" -ge 0 ]] || continue
    if grep -q "Waiting for VM Service port" "$log" && ! grep -q "VM Service URL" "$log"; then
      waited=$((waited + 5))
      if ((waited >= vm_service_wait)); then
        echo "::warning::no VM service URL after ${waited}s; stopping this attempt"
        kill "$pid" 2>/dev/null
        pkill -TERM -P "$pid" 2>/dev/null
        waited=-1
      fi
    fi
  done
  wait "$pid"
  local status=$?
  ((waited < 0)) && status=124
  sleep 1
  kill "$tail_pid" 2>/dev/null
  wait "$tail_pid" 2>/dev/null
  return "$status"
}

verbose=()
warm_pid=""
if [[ "$platform" == ios ]]; then
  # flutter_tools finds the Dart VM service URL by streaming the simulator
  # log. On a cold runner that stream can attach after the app printed the
  # URL and the run waits forever. Keep a stream open so logd is warm.
  xcrun simctl spawn "$device" log stream --style compact \
    --predicate 'processImagePath ENDSWITH "Runner"' \
    > "$logs/warm-stream.log" 2>&1 &
  warm_pid=$!
  trap '[[ -n "$warm_pid" ]] && kill "$warm_pid" 2>/dev/null' EXIT
  sleep 5
  verbose=(--verbose)
fi

flutter --version --machine > "$out/flutter-version.json" 2>/dev/null || true

# ---- device metadata -------------------------------------------------------
if [[ "$platform" == android ]]; then
  prop() { adb -s "$device" shell getprop "$1" 2>/dev/null | tr -d '\r'; }
  jq -n \
    --arg model "$(prop ro.product.model)" \
    --arg release "$(prop ro.build.version.release)" \
    --arg api "$(prop ro.build.version.sdk)" \
    --arg abi "$(prop ro.product.cpu.abi)" \
    --arg gpu "${EMULATOR_GPU:-}" \
    '{platform: "android", kind: "emulator", model: $model,
      os: ("Android " + $release + " (API " + $api + ")"), abi: $abi,
      gpu: $gpu}' > "$out/device.json"
else
  xcrun simctl list devices --json | jq --arg udid "$device" '
    .devices | to_entries[] | .key as $runtime | .value[]
    | select(.udid == $udid)
    | {platform: "ios", kind: "simulator", model: .name,
       os: ($runtime | sub("com.apple.CoreSimulator.SimRuntime."; "")
                     | sub("-(?<a>[0-9]+)-(?<b>[0-9]+)$"; " \(.a).\(.b)")),
       abi: "arm64"}' > "$out/device.json"
  xcodebuild -version | head -1 | jq -R '{xcode: .}' > "$out/xcode.json" || true
fi
cat "$out/device.json"

# ---- 1. checklist -------------------------------------------------------------
# flutter drive writes build/<TBPROF_OUT>.json through the driver.
drive() {
  local name="$1" target="$2" limit="$3" log="$4"
  shift 4
  rm -f "build/$name.json"
  TBPROF_OUT="$name" bounded "$limit" "$log" \
    flutter drive --no-pub ${verbose[@]+"${verbose[@]}"} -d "$device" \
    --driver test_driver/integration_driver.dart \
    --target "integration_test/$target" "$@"
}

checklist_rows() {
  jq '.checklist | length' "build/device_checklist.json" 2>/dev/null || echo 0
}

for attempt in 1 2; do
  drive device_checklist device_checklist_test.dart 720 \
    "$logs/checklist-$attempt.log" || true
  rows=$(checklist_rows)
  if (( rows >= checklist_min_rows )); then
    cp build/device_checklist.json "$out/device_checklist.json"
    break
  fi
  echo "::warning::$platform checklist attempt $attempt produced $rows rows"
done
if [[ ! -f "$out/device_checklist.json" ]]; then
  echo "::error::$platform checklist produced no usable result"
  status=1
fi

# ---- 2. backend profiles ----------------------------------------------------
profile_ok() {
  jq -e '.summary.frames > 0 and .summary.uiFrames > 0' "$1" > /dev/null 2>&1
}

# Android tries profile mode first; the iOS simulator cannot run it.
if [[ "$platform" == android ]]; then
  modes=(profile debug)
else
  modes=(debug)
fi

for backend in flutterRepaintBoundary nativeCpuExperimental; do
  name="profile_$backend"
  done_backend=false
  for mode in "${modes[@]}"; do
    for attempt in 1 2; do
      log="$logs/$name-$mode-$attempt.log"
      drive "$name" capture_profile_test.dart 900 "$log" "--$mode" \
        --dart-define=TUGBOAT_PROFILE=true \
        --dart-define=TUGBOAT_PROFILE_ROUNDS=2 \
        --dart-define=TUGBOAT_BACKEND="$backend" || true
      if profile_ok "build/$name.json"; then
        cp "build/$name.json" "$out/$name.json"
        done_backend=true
        break 2
      fi
      if grep -q 'TBPROF ' "$log"; then
        # The app ran and reported; a retry would not change the result.
        cp "build/$name.json" "$out/$name.json" 2>/dev/null || true
        break
      fi
      echo "::warning::$platform $backend $mode attempt $attempt gave no profile"
      [[ "$platform" == ios ]] || break
    done
    note "$platform $backend: $mode mode did not produce a profile"
  done
  if [[ "$done_backend" != true && "$backend" == flutterRepaintBoundary ]]; then
    echo "::error::$platform default-backend profile is missing"
    status=1
  fi
done

printf '%s\n' "${notes[@]+"${notes[@]}"}" | jq -R 'select(length > 0)' \
  | jq -s '{notes: .}' > "$out/notes.json"
ls -la "$out"
exit "$status"

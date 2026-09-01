#!/usr/bin/env bash
# Fail if the public Android runtime API drifted without updating api.txt (P8.27).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
golden="$root/platforms/android/capture-runtime/api.txt"
if [[ ! -f "$golden" ]]; then
  echo "::error::$golden is missing"
  exit 1
fi
actual="$(mktemp)"
python3 "$root/tool/ci/dump-android-runtime-api.py" >"$actual"
if ! diff -u "$golden" "$actual"; then
  rm -f "$actual"
  echo "::error::Android runtime public API changed. Update platforms/android/capture-runtime/api.txt with tool/ci/dump-android-runtime-api.py"
  exit 1
fi
rm -f "$actual"
echo "Android runtime API matches platforms/android/capture-runtime/api.txt"

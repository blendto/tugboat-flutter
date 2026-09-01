#!/usr/bin/env bash
# Fail if the public Swift runtime API drifted without updating api.txt (P8.28).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
golden="$root/platforms/apple/api.txt"
if [[ ! -f "$root/Package.swift" ]]; then
  echo "Package.swift is absent (Apple milestone 2). Skipping Swift API dump."
  exit 0
fi
if [[ ! -f "$golden" ]]; then
  echo "::error::$golden is missing"
  exit 1
fi
actual="$(mktemp)"
python3 "$root/tool/ci/dump-swift-runtime-api.py" >"$actual"
if ! diff -u "$golden" "$actual"; then
  rm -f "$actual"
  echo "::error::Swift runtime public API changed. Update platforms/apple/api.txt with tool/ci/dump-swift-runtime-api.py"
  exit 1
fi
rm -f "$actual"
echo "Swift runtime API matches platforms/apple/api.txt"

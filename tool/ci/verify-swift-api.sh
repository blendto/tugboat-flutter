#!/usr/bin/env bash
# Fail if the public Swift API drifted without updating api*.txt (P8.28).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ ! -f "$root/Package.swift" ]]; then
  echo "Package.swift is absent (Apple milestone 2). Skipping Swift API dump."
  exit 0
fi

verify_product() {
  local product="$1"
  local golden="$2"
  if [[ ! -f "$golden" ]]; then
    echo "::error::$golden is missing"
    exit 1
  fi
  local actual
  actual="$(mktemp)"
  python3 "$root/tool/ci/dump-swift-runtime-api.py" --product "$product" >"$actual"
  if ! diff -u "$golden" "$actual"; then
    rm -f "$actual"
    echo "::error::Swift public API ($product) changed. Update $golden:"
    echo "  python3 tool/ci/dump-swift-runtime-api.py --product $product >$golden"
    exit 1
  fi
  rm -f "$actual"
  echo "Swift API ($product) matches $golden"
}

verify_product capture-runtime "$root/platforms/apple/api.txt"
verify_product tugboat "$root/platforms/apple/api-tugboat.txt"

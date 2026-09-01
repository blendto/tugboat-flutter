#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root/sdks/flutter/packages/tugboat"

generated=(
  lib/src/native_capture.g.dart
  android/src/main/kotlin/com/tugboat/flutter/NativeCapture.g.kt
  ios/Classes/NativeCapture.g.swift
)

before="$(mktemp)"
after="$(mktemp)"
trap 'rm -f "$before" "$after"' EXIT

{
  for file in "${generated[@]}"; do
    printf '%s\n' "$file"
    cat "$file"
  done
} >"$before"

dart run pigeon --input pigeons/native_capture.dart

{
  for file in "${generated[@]}"; do
    printf '%s\n' "$file"
    cat "$file"
  done
} >"$after"

if ! cmp -s "$before" "$after"; then
  echo "Pigeon outputs are stale. Run tool/ci/generate-native-capture-pigeon.sh" >&2
  diff -u "$before" "$after" | head -n 80 >&2 || true
  exit 1
fi
echo "Pigeon outputs are current."

plugin="ios/Classes/TugboatPlugin.swift"
if grep -Eq '^[[:space:]]+public func (getCapabilities|capture|cancel|dispose)' "$plugin"; then
  echo "iOS Pigeon protocol methods must not expose internal generated types as public API." >&2
  exit 1
fi
echo "iOS Pigeon protocol method visibility is valid."

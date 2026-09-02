#!/usr/bin/env bash
# Print the Flutter plugin's CocoaPods TugboatCaptureRuntime pin, if any.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
file="$root/sdks/flutter/packages/tugboat/ios/tugboat.podspec"
if [[ ! -f "$file" ]]; then
  echo "missing $file" >&2
  exit 1
fi
line="$(grep -E "s\.dependency[[:space:]]+'TugboatCaptureRuntime'" "$file" | head -1 || true)"
if [[ -z "$line" ]]; then
  echo ""
  exit 0
fi
pin="$(printf '%s\n' "$line" | sed -E "s/.*TugboatCaptureRuntime'[[:space:]]*,[[:space:]]*'([^']+)'.*/\1/")"
if [[ -z "$pin" || "$pin" == "$line" ]]; then
  echo "Could not read TugboatCaptureRuntime pin from $file" >&2
  exit 1
fi
printf '%s\n' "$pin"

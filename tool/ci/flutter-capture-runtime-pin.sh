#!/usr/bin/env bash
# Print the Flutter plugin's Maven Central capture-runtime pin.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
file="$root/sdks/flutter/packages/tugboat/android/build.gradle"
if [[ ! -f "$file" ]]; then
  echo "missing $file" >&2
  exit 1
fi
pin="$(
  grep -E 'implementation\("com\.gettugboat\.sdk:capture-runtime:[^"]+"\)' "$file" \
    | head -1 \
    | sed -E 's/.*capture-runtime:([^"]+)".*/\1/'
)"
if [[ -z "$pin" ]]; then
  echo "Could not read capture-runtime pin from $file" >&2
  exit 1
fi
printf '%s\n' "$pin"

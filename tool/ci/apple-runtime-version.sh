#!/usr/bin/env bash
# Print TugboatCaptureRuntime version from the root podspec.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
file="$root/TugboatCaptureRuntime.podspec"
if [[ ! -f "$file" ]]; then
  echo "missing $file" >&2
  exit 1
fi
version="$(grep -E "s\.version[[:space:]]*=" "$file" | head -1 | sed -E "s/.*['\"]([0-9][^'\"]*)['\"].*/\1/")"
if [[ -z "$version" ]]; then
  echo "Could not read s.version from $file" >&2
  exit 1
fi
printf '%s\n' "$version"

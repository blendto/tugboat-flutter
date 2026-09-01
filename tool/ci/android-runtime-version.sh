#!/usr/bin/env bash
# Print capture-runtime VERSION_NAME from platforms/android/gradle.properties.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
file="$root/platforms/android/gradle.properties"
if [[ ! -f "$file" ]]; then
  echo "missing $file" >&2
  exit 1
fi
version="$(grep -E '^VERSION_NAME=' "$file" | head -1 | cut -d= -f2- | tr -d '[:space:]')"
if [[ -z "$version" ]]; then
  echo "VERSION_NAME is empty in $file" >&2
  exit 1
fi
printf '%s\n' "$version"

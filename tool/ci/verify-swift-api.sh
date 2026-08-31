#!/usr/bin/env bash
# Swift API surface check (P8.28). Apple packaging is milestone 2.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ ! -f "$root/Package.swift" ]]; then
  echo "Package.swift is absent (Apple milestone 2). Skipping Swift API dump."
  exit 0
fi
echo "::error::Package.swift exists; add a Swift API dump before enabling this check."
exit 1

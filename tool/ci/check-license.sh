#!/usr/bin/env bash
# Confirm the repository license stays AGPL-3.0-only (P8.30).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

if [[ ! -f LICENSE ]]; then
  echo "::error::LICENSE is missing"
  exit 1
fi

if ! grep -q "GNU AFFERO GENERAL PUBLIC LICENSE" LICENSE; then
  echo "::error::LICENSE is not GNU AGPL"
  exit 1
fi

if ! grep -q "Version 3" LICENSE; then
  echo "::error::LICENSE is not AGPL version 3"
  exit 1
fi

check_pubspec() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "::error::$file is missing"
    exit 1
  fi
  if ! grep -Eq '^license:[[:space:]]*AGPL-3.0-only[[:space:]]*$' "$file"; then
    echo "::error::$file must declare license: AGPL-3.0-only"
    exit 1
  fi
}

check_pubspec sdks/flutter/packages/tugboat/pubspec.yaml
check_pubspec sdks/flutter/packages/tugboat_dio/pubspec.yaml

echo "License check passed (AGPL-3.0-only)."

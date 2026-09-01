#!/usr/bin/env bash
# dart pub publish --dry-run for Flutter packages (P8.29).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
export PATH="${FLUTTER_ROOT:-$HOME/sdk/flutter}/bin:$PATH"
dart pub get

run_one() {
  local dir="$1"
  echo "pub publish --dry-run in $dir"
  (cd "$dir" && dart pub publish --dry-run)
}

run_one sdks/flutter/packages/tugboat
run_one sdks/flutter/packages/tugboat_dio

#!/usr/bin/env bash
# Formats every tracked Dart file, or with --check fails if any would change.
# Pigeon output (*.g.dart) is skipped: Pigeon formats it differently and
# verify-native-capture-pigeon.sh requires it byte-for-byte.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

args=()
case "${1:-}" in
  --check) args=(--output=none --set-exit-if-changed) ;;
  "") ;;
  *)
    echo "usage: $0 [--check]" >&2
    exit 1
    ;;
esac

git ls-files -z '*.dart' ':!:*.g.dart' | xargs -0 dart format ${args[@]+"${args[@]}"}

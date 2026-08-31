#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"

run_package() {
  local name="$1"
  cd "$root/sdks/flutter/packages/$name"
  flutter test -j 1 .
}

case "${1:-all}" in
  all)
    run_package tugboat
    run_package tugboat_dio
    ;;
  tugboat | tugboat_dio)
    run_package "$1"
    ;;
  *)
    echo "usage: $0 [all|tugboat|tugboat_dio]" >&2
    exit 1
    ;;
esac

#!/usr/bin/env bash
# Runs package tests. Test files run in parallel; the wall-clock tap benchmark
# (tag `benchmark`) then runs alone so nothing competes with it for CPU.
# Set TUGBOAT_SKIP_BENCHMARKS=1 to leave the benchmark out, as CI does: its
# budgets are a local regression guard, not a gate for shared runners.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"

run_package() {
  local name="$1"
  cd "$root/sdks/flutter/packages/$name"
  if [ "$name" != tugboat ]; then
    flutter test .
    return
  fi
  flutter test --exclude-tags benchmark .
  if [ "${TUGBOAT_SKIP_BENCHMARKS:-0}" != 1 ]; then
    flutter test -j 1 test/tap_resolution_benchmark_test.dart
  fi
}

case "${1:-all}" in
  all)
    run_package tugboat
    run_package tugboat_dio
    run_package tugboat_http
    run_package tugboat_build
    ;;
  tugboat | tugboat_dio | tugboat_http | tugboat_build)
    run_package "$1"
    ;;
  *)
    echo "usage: $0 [all|tugboat|tugboat_dio|tugboat_http|tugboat_build]" >&2
    exit 1
    ;;
esac

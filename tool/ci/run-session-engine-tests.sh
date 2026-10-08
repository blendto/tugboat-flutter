#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
build="$root/build/session-engine"
cmake \
  -S "$root/core/session-engine" \
  -B "$build" \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_C_COMPILER=gcc \
  -DCMAKE_CXX_COMPILER=g++ \
  -DTB_SESSION_ENGINE_SANITIZE=ON
cmake --build "$build"
ctest --test-dir "$build" --output-on-failure

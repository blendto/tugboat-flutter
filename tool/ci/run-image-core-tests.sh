#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
build="$root/build/image-core"
cmake \
  -S "$root/core/image-processing" \
  -B "$build" \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_C_COMPILER=gcc \
  -DCMAKE_CXX_COMPILER=g++ \
  -DTB_IMAGE_CORE_SANITIZE=ON
cmake --build "$build"
ctest --test-dir "$build" --output-on-failure

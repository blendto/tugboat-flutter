#!/usr/bin/env bash
# Lint the unpublished-or-hosted TugboatCaptureRuntime podspec (needs Xcode).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
pod lib lint TugboatCaptureRuntime.podspec \
  --platforms=ios \
  --swift-version=5.9 \
  --allow-warnings \
  --fail-fast

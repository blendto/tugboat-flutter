#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root/sdks/flutter/packages/tugboat"
dart run pigeon --input pigeons/native_capture.dart

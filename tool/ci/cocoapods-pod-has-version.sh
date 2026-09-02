#!/usr/bin/env bash
# Exit 0 if CocoaPods trunk has TugboatCaptureRuntime at $1.
set -euo pipefail
version="${1:-}"
if [[ -z "$version" ]]; then
  echo "usage: cocoapods-pod-has-version.sh <version>" >&2
  exit 2
fi
url="https://trunk.cocoapods.org/api/v1/pods/TugboatCaptureRuntime"
code="$(curl -sS -o /tmp/tugboat-cocoapods-pod.json -w '%{http_code}' "$url" || true)"
if [[ "$code" != "200" ]]; then
  exit 1
fi
python3 - "$version" <<'PY'
import json
import sys

wanted = sys.argv[1]
with open("/tmp/tugboat-cocoapods-pod.json", encoding="utf-8") as fh:
    data = json.load(fh)
versions = data.get("versions") or []
names = []
for item in versions:
    if isinstance(item, str):
        names.append(item)
    elif isinstance(item, dict):
        name = item.get("name") or item.get("number")
        if name:
            names.append(str(name))
sys.exit(0 if wanted in names else 1)
PY

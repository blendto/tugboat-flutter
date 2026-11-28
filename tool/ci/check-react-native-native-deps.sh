#!/usr/bin/env bash
# Exit 0 only if the native SDKs @tugboat-ai/react-native pins are published:
# tugboat-android and tugboat-okhttp (and the com.gettugboat.sdk artifacts they
# depend on) on Maven Central, and the Tugboat pod on CocoaPods trunk (trunk
# rejects a pod whose dependencies are missing). An npm release without them
# cannot be installed, and npm never lets a version number be reused.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root/sdks/react-native"

android_version="$(sed -nE 's/^def tugboatAndroidVersion = "([^"]+)".*/\1/p' android/build.gradle | head -1)"
pod_version="$(sed -nE 's/^[[:space:]]*s\.dependency "Tugboat", "([^"]+)".*/\1/p' TugboatReactNative.podspec | head -1)"
if [[ -z "$android_version" ]]; then
  echo "::error::Could not read tugboatAndroidVersion from android/build.gradle."
  exit 1
fi
if [[ -z "$pod_version" ]]; then
  echo "::error::TugboatReactNative.podspec must pin the Tugboat pod to an exact version (s.dependency \"Tugboat\", \"<version>\")."
  exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

missing=0
# Checks com.gettugboat.sdk:<artifact>:<version> on Maven Central, then every
# com.gettugboat.sdk artifact its POM depends on (tugboat-android needs
# capture-runtime), so the gate cannot pass on a half-published SDK.
queue=("tugboat-android:${android_version}" "tugboat-okhttp:${android_version}")
seen=" "
while ((${#queue[@]})); do
  coordinate="${queue[0]}"
  queue=("${queue[@]:1}")
  [[ "$seen" == *" ${coordinate} "* ]] && continue
  seen+="${coordinate} "
  artifact="${coordinate%%:*}"
  version="${coordinate#*:}"
  pom="https://repo1.maven.org/maven2/com/gettugboat/sdk/${artifact}/${version}/${artifact}-${version}.pom"
  code="$(curl -sS -o "$tmp" -w '%{http_code}' "$pom" || true)"
  if [[ "$code" != "200" ]]; then
    echo "::error::Maven Central does not have com.gettugboat.sdk:${artifact}:${version} (HTTP ${code})."
    missing=1
    continue
  fi
  echo "Maven Central has com.gettugboat.sdk:${artifact}:${version}."
  deps="$(python3 - "$tmp" <<'PY'
import sys
import xml.etree.ElementTree as ET

ns = {"m": "http://maven.apache.org/POM/4.0.0"}
root = ET.parse(sys.argv[1]).getroot()
for dep in root.findall("m:dependencies/m:dependency", ns):
    group = dep.findtext("m:groupId", default="", namespaces=ns).strip()
    artifact = dep.findtext("m:artifactId", default="", namespaces=ns).strip()
    version = dep.findtext("m:version", default="", namespaces=ns).strip()
    if group == "com.gettugboat.sdk" and artifact and version:
        print(f"{artifact}:{version}")
PY
)"
  for dep in $deps; do
    queue+=("$dep")
  done
done

code="$(curl -sS -o "$tmp" -w '%{http_code}' "https://trunk.cocoapods.org/api/v1/pods/Tugboat" || true)"
if [[ "$code" == "200" ]] && python3 - "$pod_version" "$tmp" <<'PY'
import json
import sys

wanted, path = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    versions = json.load(fh).get("versions") or []
names = {str(v.get("name") or v.get("number")) if isinstance(v, dict) else str(v) for v in versions}
sys.exit(0 if wanted in names else 1)
PY
then
  echo "CocoaPods trunk has Tugboat ${pod_version}."
else
  echo "::error::CocoaPods trunk does not have Tugboat ${pod_version} (HTTP ${code})."
  missing=1
fi

exit "$missing"

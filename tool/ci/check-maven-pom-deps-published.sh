#!/usr/bin/env bash
# Exit 0 only if every com.gettugboat.sdk dependency in the POM at $1 is on
# Maven Central. Maven Central accepts a POM whose dependencies are missing,
# and a release there is permanent, so publish jobs check first.
set -euo pipefail
pom_file="${1:-}"
if [[ -z "$pom_file" || ! -f "$pom_file" ]]; then
  echo "usage: check-maven-pom-deps-published.sh <pom-file>" >&2
  exit 2
fi

deps="$(python3 - "$pom_file" <<'PY'
import sys
import xml.etree.ElementTree as ET

ns = {"m": "http://maven.apache.org/POM/4.0.0"}
root = ET.parse(sys.argv[1]).getroot()
for dep in root.findall("m:dependencies/m:dependency", ns):
    group = dep.findtext("m:groupId", default="", namespaces=ns).strip()
    artifact = dep.findtext("m:artifactId", default="", namespaces=ns).strip()
    version = dep.findtext("m:version", default="", namespaces=ns).strip()
    if group == "com.gettugboat.sdk":
        print(f"{artifact}:{version}")
PY
)"

missing=0
for dep in $deps; do
  artifact="${dep%%:*}"
  version="${dep#*:}"
  if [[ -z "$version" ]]; then
    echo "::error::${artifact} has no version in ${pom_file}."
    missing=1
    continue
  fi
  pom="https://repo1.maven.org/maven2/com/gettugboat/sdk/${artifact}/${version}/${artifact}-${version}.pom"
  code="$(curl -sS -o /dev/null -w '%{http_code}' "$pom" || true)"
  if [[ "$code" == "200" ]]; then
    echo "Maven Central has com.gettugboat.sdk:${artifact}:${version}."
  else
    echo "::error::Maven Central does not have com.gettugboat.sdk:${artifact}:${version} (HTTP ${code}). Publish it first."
    missing=1
  fi
done
exit "$missing"

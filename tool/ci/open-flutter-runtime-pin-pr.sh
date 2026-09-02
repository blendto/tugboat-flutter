#!/usr/bin/env bash
# After capture-runtime is on Maven Central, open a Flutter PR that pins it.
# No-op if the plugin already depends on VERSION_NAME, or if a pin PR exists.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

runtime="$(bash tool/ci/android-runtime-version.sh)"
pin="$(bash tool/ci/flutter-capture-runtime-pin.sh)"
if [[ "$pin" == "$runtime" ]]; then
  echo "Flutter plugin already pins capture-runtime ${runtime}."
  exit 0
fi

pom="https://repo1.maven.org/maven2/com/gettugboat/sdk/capture-runtime/${runtime}/capture-runtime-${runtime}.pom"
echo "Waiting for Maven Central ${runtime} (${pom})."
ready=false
for attempt in $(seq 1 40); do
  code="$(curl -sS -o /dev/null -w '%{http_code}' "$pom" || true)"
  if [[ "$code" == "200" ]]; then
    ready=true
    break
  fi
  echo "repo1 HTTP ${code} (attempt ${attempt}); sleeping 15s."
  sleep 15
done
if [[ "$ready" != "true" ]]; then
  echo "::error::capture-runtime ${runtime} is not on Maven Central yet; not opening a Flutter pin PR."
  exit 1
fi

branch="chore/pin-capture-runtime-${runtime}"
if [[ -n "${GH_TOKEN:-}" ]] && command -v gh >/dev/null; then
  open_count="$(gh pr list --head "$branch" --state open --json number --jq 'length' || echo 0)"
  if [[ "${open_count:-0}" -gt 0 ]]; then
    echo "Open PR already exists for ${branch}."
    gh pr list --head "$branch" --state open --json url --jq '.[0].url'
    exit 0
  fi
fi

if git ls-remote --exit-code origin "refs/heads/${branch}" >/dev/null 2>&1; then
  echo "Branch ${branch} already exists on origin."
  exit 0
fi

current="$(grep -E '^version:' sdks/flutter/packages/tugboat/pubspec.yaml | head -1 | sed -E 's/^version:[[:space:]]*//' | tr -d '"' | tr -d "'" | tr -d '[:space:]')"
if [[ ! "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error::Cannot bump non-semver Flutter version ${current}."
  exit 1
fi
IFS=. read -r major minor patch <<<"$current"
flutter="${major}.${minor}.$((patch + 1))"
echo "Pinning capture-runtime ${pin} -> ${runtime}; tugboat ${current} -> ${flutter}."

python3 - "$runtime" "$flutter" "$current" <<'PY'
import re
import sys
from pathlib import Path

runtime, flutter, previous = sys.argv[1], sys.argv[2], sys.argv[3]
root = Path(".")

gradle = root / "sdks/flutter/packages/tugboat/android/build.gradle"
text = gradle.read_text()
text = re.sub(r'^version = "[^"]+"', f'version = "{flutter}"', text, count=1, flags=re.M)
text = re.sub(
    r'implementation\("com\.gettugboat\.sdk:capture-runtime:[^"]+"\)',
    f'implementation("com.gettugboat.sdk:capture-runtime:{runtime}")',
    text,
    count=1,
)
gradle.write_text(text)

def set_pubspec_version(path: Path) -> None:
    body = path.read_text()
    body = re.sub(r'^version:.*$', f'version: {flutter}', body, count=1, flags=re.M)
    path.write_text(body)

set_pubspec_version(root / "sdks/flutter/packages/tugboat/pubspec.yaml")
set_pubspec_version(root / "sdks/flutter/packages/tugboat_dio/pubspec.yaml")

dio = root / "sdks/flutter/packages/tugboat_dio/pubspec.yaml"
dio.write_text(
    re.sub(
        r'^  tugboat: \^.*$',
        f'  tugboat: ^{flutter}',
        dio.read_text(),
        count=1,
        flags=re.M,
    )
)

example = root / "sdks/flutter/packages/tugboat/example/pubspec.yaml"
example.write_text(
    re.sub(
        r'^  tugboat: \^.*$',
        f'  tugboat: ^{flutter}',
        example.read_text(),
        count=1,
        flags=re.M,
    )
)

sdk = root / "sdks/flutter/packages/tugboat/lib/src/sdk_version.dart"
sdk.write_text(
    re.sub(
        r"const tugboatSdkVersion = '[^']+';",
        f"const tugboatSdkVersion = '{flutter}';",
        sdk.read_text(),
        count=1,
    )
)

def prepend_changelog(path: Path, body: str) -> None:
    path.write_text(body + path.read_text())

prepend_changelog(
    root / "sdks/flutter/packages/tugboat/CHANGELOG.md",
    f"## {flutter}\n\nDepend on Maven Central `com.gettugboat.sdk:capture-runtime:{runtime}`.\n\n",
)
prepend_changelog(
    root / "sdks/flutter/packages/tugboat_dio/CHANGELOG.md",
    f"## {flutter}\n\n### Changed\n\n- Compatibility release for `tugboat` {flutter}. The Dio adapter has no runtime\n  behavior change.\n\n",
)

compat = root / "docs/releases/compatibility.md"
compat_text = compat.read_text()
header = "| Adapter | Adapter version | Native runtime |\n| --- | --- | --- |\n"
row = (
    f"| Flutter `tugboat` | {flutter} | Android "
    f"`com.gettugboat.sdk:capture-runtime:{runtime}` from Maven Central. "
    "Apple `TugboatCaptureRuntime` 0.1.x compiled from monorepo sources "
    "(unpublished CocoaPod is not required). Plugin iOS floor 12; native "
    "capture still reports unsupported below iOS 15. |\n"
)
if f"| Flutter `tugboat` | {flutter} |" not in compat_text:
    if header not in compat_text:
        raise SystemExit("compatibility table header not found")
    compat_text = compat_text.replace(header, header + row, 1)
compat_text = re.sub(
    rf"Flutter `{re.escape(previous)}` consumes `capture-runtime`",
    f"Flutter `{flutter}` consumes `capture-runtime`",
    compat_text,
    count=1,
)
compat.write_text(compat_text)
PY

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git checkout -b "$branch"
git add \
  sdks/flutter/packages/tugboat/android/build.gradle \
  sdks/flutter/packages/tugboat/pubspec.yaml \
  sdks/flutter/packages/tugboat/lib/src/sdk_version.dart \
  sdks/flutter/packages/tugboat/CHANGELOG.md \
  sdks/flutter/packages/tugboat/example/pubspec.yaml \
  sdks/flutter/packages/tugboat_dio/pubspec.yaml \
  sdks/flutter/packages/tugboat_dio/CHANGELOG.md \
  docs/releases/compatibility.md
git commit -m "$(cat <<EOF
Pin Flutter plugin to capture-runtime ${runtime}.

EOF
)"
git push -u origin HEAD

if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "Pushed ${branch}; GH_TOKEN is unset so the PR was not opened."
  exit 0
fi

url="$(
  gh pr create --base main --head "$branch" --title "Pin Flutter to capture-runtime ${runtime}" --body "$(cat <<EOF
## Summary
- Maven Central now has \`com.gettugboat.sdk:capture-runtime:${runtime}\`.
- Pin the Android plugin to that coordinate and bump \`tugboat\` / \`tugboat_dio\` to \`${flutter}\`.

Merging publishes \`${flutter}\` to pub.dev via \`publish.yml\`.

## Test plan
- [ ] Version policy CI is green
- [ ] Android example/host resolves \`capture-runtime:${runtime}\` from Maven Central
- [ ] After merge, pub.dev has \`tugboat\` \`${flutter}\`

EOF
)"
)"
echo "$url"

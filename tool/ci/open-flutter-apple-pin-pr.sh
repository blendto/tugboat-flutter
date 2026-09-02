#!/usr/bin/env bash
# After TugboatCaptureRuntime is on CocoaPods trunk, open a Flutter PR that pins it.
# No-op if the plugin already depends on s.version, or if a pin PR exists.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

runtime="$(bash tool/ci/apple-runtime-version.sh)"
pin="$(bash tool/ci/flutter-apple-runtime-pin.sh)"
if [[ "$pin" == "$runtime" ]]; then
  echo "Flutter plugin already pins TugboatCaptureRuntime ${runtime}."
  exit 0
fi

echo "Waiting for CocoaPods trunk TugboatCaptureRuntime ${runtime}."
ready=false
for attempt in $(seq 1 40); do
  if bash tool/ci/cocoapods-pod-has-version.sh "$runtime"; then
    ready=true
    break
  fi
  echo "trunk does not have ${runtime} yet (attempt ${attempt}); sleeping 15s."
  sleep 15
done
if [[ "$ready" != "true" ]]; then
  echo "::error::TugboatCaptureRuntime ${runtime} is not on CocoaPods trunk yet; not opening a Flutter pin PR."
  exit 1
fi

branch="chore/pin-tugboat-capture-runtime-${runtime}"
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

if [[ -z "$pin" ]]; then
  echo "::error::Flutter plugin has no TugboatCaptureRuntime pin; apply the iOS 15 CocoaPods consume change in a dedicated PR."
  exit 1
fi

current="$(grep -E '^version:' sdks/flutter/packages/tugboat/pubspec.yaml | head -1 | sed -E 's/^version:[[:space:]]*//' | tr -d '"' | tr -d "'" | tr -d '[:space:]')"
if [[ ! "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error::Cannot bump non-semver Flutter version ${current}."
  exit 1
fi
IFS=. read -r major minor patch <<<"$current"
flutter="${major}.${minor}.$((patch + 1))"
echo "Pinning TugboatCaptureRuntime ${pin} -> ${runtime}; tugboat ${current} -> ${flutter}."

python3 - "$runtime" "$flutter" "$current" <<'PY'
import re
import sys
from pathlib import Path

runtime, flutter, previous = sys.argv[1], sys.argv[2], sys.argv[3]
root = Path(".")

podspec = root / "sdks/flutter/packages/tugboat/ios/tugboat.podspec"
text = podspec.read_text()
text = re.sub(r"^  s\.version\s+=\s+'[^']+'", f"  s.version          = '{flutter}'", text, count=1, flags=re.M)
text = re.sub(
    r"s\.dependency 'TugboatCaptureRuntime', '[^']+'",
    f"s.dependency 'TugboatCaptureRuntime', '{runtime}'",
    text,
    count=1,
)
podspec.write_text(text)

gradle = root / "sdks/flutter/packages/tugboat/android/build.gradle"
gradle.write_text(re.sub(r'^version = "[^"]+"', f'version = "{flutter}"', gradle.read_text(), count=1, flags=re.M))

def set_pubspec_version(path: Path) -> None:
    path.write_text(re.sub(r'^version:.*$', f'version: {flutter}', path.read_text(), count=1, flags=re.M))

set_pubspec_version(root / "sdks/flutter/packages/tugboat/pubspec.yaml")
set_pubspec_version(root / "sdks/flutter/packages/tugboat_dio/pubspec.yaml")

for rel in (
    "sdks/flutter/packages/tugboat_dio/pubspec.yaml",
    "sdks/flutter/packages/tugboat/example/pubspec.yaml",
):
    path = root / rel
    path.write_text(re.sub(r'^  tugboat: \^.*$', f'  tugboat: ^{flutter}', path.read_text(), count=1, flags=re.M))

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
    f"## {flutter}\n\nDepend on CocoaPods `TugboatCaptureRuntime:{runtime}`.\n\n",
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
    f"`com.gettugboat.sdk:capture-runtime:0.1.0` from Maven Central. "
    f"Apple `TugboatCaptureRuntime` `{runtime}` from CocoaPods trunk. "
    "Plugin iOS floor 15. |\n"
)
if f"| Flutter `tugboat` | {flutter} |" not in compat_text:
    if header not in compat_text:
        raise SystemExit("compatibility table header not found")
    compat_text = compat_text.replace(header, header + row, 1)
compat.write_text(compat_text)
PY

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git checkout -b "$branch"
git add \
  sdks/flutter/packages/tugboat/ios/tugboat.podspec \
  sdks/flutter/packages/tugboat/android/build.gradle \
  sdks/flutter/packages/tugboat/pubspec.yaml \
  sdks/flutter/packages/tugboat/lib/src/sdk_version.dart \
  sdks/flutter/packages/tugboat/CHANGELOG.md \
  sdks/flutter/packages/tugboat/example/pubspec.yaml \
  sdks/flutter/packages/tugboat_dio/pubspec.yaml \
  sdks/flutter/packages/tugboat_dio/CHANGELOG.md \
  docs/releases/compatibility.md
git commit -m "$(cat <<EOF
Pin Flutter plugin to TugboatCaptureRuntime ${runtime}.

EOF
)"
git push -u origin HEAD

if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "Pushed ${branch}; GH_TOKEN is unset so the PR was not opened."
  exit 0
fi

url="$(
  gh pr create --base main --head "$branch" --title "Pin Flutter to TugboatCaptureRuntime ${runtime}" --body "$(cat <<EOF
## Summary
- CocoaPods trunk now has \`TugboatCaptureRuntime\` \`${runtime}\`.
- Pin the iOS plugin to that pod and bump \`tugboat\` / \`tugboat_dio\` to \`${flutter}\`.

Merging publishes \`${flutter}\` to pub.dev via \`publish.yml\`.

## Test plan
- [ ] Version policy CI is green
- [ ] Flutter Apple pin is on CocoaPods trunk check is green
- [ ] After merge, pub.dev has \`tugboat\` \`${flutter}\`

EOF
)"
)"
echo "$url"

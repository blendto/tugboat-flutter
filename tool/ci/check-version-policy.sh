#!/usr/bin/env bash
# Path-aware version policy (P8.21–P8.25).
#
# Flutter adapter source → tugboat version must increase, and
# docs/releases/compatibility.md must change.
# Android public Kotlin API or C ABI headers → capture-runtime version
# must increase, and the compatibility table must change.
# Documentation-only and C++ test/fuzz-only changes skip the Flutter bump.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

if [[ -z "${BASE_SHA:-}" ]]; then
  echo "BASE_SHA is required (PR base or merge-base commit)." >&2
  exit 2
fi

extract_pubspec_version() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo ""
    return
  fi
  grep -E '^version:' "$file" | head -1 | sed -E 's/^version:[[:space:]]*//' | tr -d '"' | tr -d "'" | tr -d '[:space:]'
}

extract_runtime_version() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo ""
    return
  fi
  awk '
    /artifactId[[:space:]]*=[[:space:]]*"capture-runtime"/ { seen = 1 }
    seen && /version[[:space:]]*=[[:space:]]*"/ {
      if (match($0, /"[0-9][^"]*"/)) {
        print substr($0, RSTART + 1, RLENGTH - 2)
        exit
      }
    }
  ' "$file"
}

pubspec_in_git() {
  local sha="$1"
  if git cat-file -e "${sha}:sdks/flutter/packages/tugboat/pubspec.yaml" 2>/dev/null; then
    echo sdks/flutter/packages/tugboat/pubspec.yaml
  elif git cat-file -e "${sha}:packages/tugboat/pubspec.yaml" 2>/dev/null; then
    echo packages/tugboat/pubspec.yaml
  else
    echo ""
  fi
}

runtime_gradle="platforms/android/capture-runtime/build.gradle.kts"
compat_file="docs/releases/compatibility.md"
head_pubspec="sdks/flutter/packages/tugboat/pubspec.yaml"

mapfile -t changed < <(
  {
    git diff --name-only "$BASE_SHA"
    git ls-files --others --exclude-standard
  } | awk 'NF && !seen[$0]++'
)

if [[ ${#changed[@]} -eq 0 ]]; then
  echo "No file changes vs $BASE_SHA."
  exit 0
fi

echo "Changed files vs $BASE_SHA:"
printf '  %s\n' "${changed[@]}"

needs_flutter_bump=0
needs_runtime_bump=0
needs_compat=0

is_flutter_adapter() {
  local f="$1"
  case "$f" in
    sdks/flutter/packages/tugboat/lib/* | \
    sdks/flutter/packages/tugboat/android/* | \
    sdks/flutter/packages/tugboat/ios/* | \
    sdks/flutter/packages/tugboat/pigeons/* | \
    sdks/flutter/packages/tugboat/pubspec.yaml)
      return 0
      ;;
  esac
  return 1
}

is_runtime_public_api() {
  local f="$1"
  case "$f" in
    core/image-processing/include/*)
      return 0
      ;;
    platforms/android/capture-runtime/src/main/java/com/tugboat/capture/internal/*)
      return 1
      ;;
    platforms/android/capture-runtime/src/main/java/com/tugboat/capture/*)
      return 0
      ;;
  esac
  return 1
}

for f in "${changed[@]}"; do
  if is_flutter_adapter "$f"; then
    needs_flutter_bump=1
    needs_compat=1
  fi
  if is_runtime_public_api "$f"; then
    needs_runtime_bump=1
    needs_compat=1
  fi
done

require_greater_version() {
  local label="$1"
  local base_version="$2"
  local head_version="$3"
  if [[ "$head_version" == "$base_version" ]]; then
    echo "::error::$label version must be bumped before merge (still $base_version)."
    exit 1
  fi
  local higher
  higher="$(printf '%s\n%s\n' "$base_version" "$head_version" | sort -V | tail -n 1)"
  if [[ "$higher" != "$head_version" ]]; then
    echo "::error::$label PR version ($head_version) must be greater than base ($base_version)."
    exit 1
  fi
  echo "$label version bump: $base_version -> $head_version"
}

if [[ "$needs_flutter_bump" -eq 1 ]]; then
  if [[ ! -f "$head_pubspec" ]]; then
    echo "::error::tugboat pubspec.yaml is missing on this branch"
    exit 1
  fi
  head_version="$(extract_pubspec_version "$head_pubspec")"
  if [[ -z "$head_version" ]]; then
    echo "::error::Could not read version from $head_pubspec"
    exit 1
  fi
  base_pubspec="$(pubspec_in_git "$BASE_SHA")"
  if [[ -z "$base_pubspec" ]]; then
    echo "Base branch has no tugboat pubspec; treating as new package (ok)."
    echo "PR version: $head_version"
  else
    base_file="$(mktemp)"
    git show "${BASE_SHA}:${base_pubspec}" >"$base_file"
    base_version="$(extract_pubspec_version "$base_file")"
    rm -f "$base_file"
    if [[ -z "$base_version" ]]; then
      echo "::error::Could not read version from base $base_pubspec"
      exit 1
    fi
    echo "Base Flutter version: $base_version ($base_pubspec)"
    echo "PR Flutter version:   $head_version ($head_pubspec)"
    require_greater_version "tugboat" "$base_version" "$head_version"
  fi
else
  echo "No Flutter adapter source changes; skipping tugboat version bump."
fi

if [[ "$needs_runtime_bump" -eq 1 ]]; then
  head_runtime="$(extract_runtime_version "$runtime_gradle")"
  if [[ -z "$head_runtime" ]]; then
    echo "::error::Could not read capture-runtime version from $runtime_gradle"
    exit 1
  fi
  if git cat-file -e "${BASE_SHA}:${runtime_gradle}" 2>/dev/null; then
    base_file="$(mktemp)"
    git show "${BASE_SHA}:${runtime_gradle}" >"$base_file"
    base_runtime="$(extract_runtime_version "$base_file")"
    rm -f "$base_file"
    if [[ -z "$base_runtime" ]]; then
      echo "::error::Could not read capture-runtime version from base $runtime_gradle"
      exit 1
    fi
    echo "Base runtime version: $base_runtime"
    echo "PR runtime version:   $head_runtime"
    require_greater_version "capture-runtime" "$base_runtime" "$head_runtime"
  else
    echo "Base has no capture-runtime; new artifact $head_runtime (ok)."
  fi
else
  echo "No public runtime API / C ABI changes; skipping capture-runtime version bump."
fi

if [[ "$needs_compat" -eq 1 ]]; then
  if git diff --name-only "$BASE_SHA" | grep -qx "$compat_file"; then
    echo "Compatibility table updated ($compat_file)."
  elif git ls-files --others --exclude-standard | grep -qx "$compat_file"; then
    echo "Compatibility table added ($compat_file)."
  else
    echo "::error::Adapter or public runtime API changed; update $compat_file."
    exit 1
  fi
else
  echo "No adapter/runtime API pairing change; compatibility table not required."
fi

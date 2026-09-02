#!/usr/bin/env bash
# Path-aware version policy (P8.21–P8.25).
#
# Flutter adapter source → tugboat version must increase, and
# docs/releases/compatibility.md must change.
# Android public Kotlin API or C ABI headers → capture-runtime version
# must increase, and the compatibility table must change.
# Apple public Swift API or TugboatCaptureRuntime.podspec → Apple runtime
# version must increase, and the compatibility table must change.
# Documentation-only and C++ test/fuzz-only changes skip the Flutter bump.
# Flutter's Maven pin must not be newer than capture-runtime VERSION_NAME.
# Changing that pin requires it to equal VERSION_NAME; runtime-only PRs may lag.
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

extract_runtime_version_from_text() {
  local content="$1"
  if printf '%s\n' "$content" | grep -qE '^VERSION_NAME='; then
    printf '%s\n' "$content" | grep -E '^VERSION_NAME=' | head -1 | cut -d= -f2- | tr -d '[:space:]'
    return
  fi
  printf '%s\n' "$content" | awk '
    /artifactId[[:space:]]*=[[:space:]]*"capture-runtime"/ { seen = 1 }
    seen && /version[[:space:]]*=[[:space:]]*"/ {
      if (match($0, /"[0-9][^"]*"/)) {
        print substr($0, RSTART + 1, RLENGTH - 2)
        exit
      }
    }
  '
}

extract_plugin_pin_from_text() {
  local content="$1"
  local line
  line="$(printf '%s\n' "$content" | grep -E 'implementation\("com\.gettugboat\.sdk:capture-runtime:[^"]+"\)' | head -1 || true)"
  if [[ -z "$line" ]]; then
    echo ""
    return
  fi
  printf '%s\n' "$line" | sed -E 's/.*capture-runtime:([^"]+)".*/\1/'
}

extract_runtime_version() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo ""
    return
  fi
  extract_runtime_version_from_text "$(cat "$file")"
}

extract_runtime_version_at() {
  local sha="$1"
  if git cat-file -e "${sha}:platforms/android/gradle.properties" 2>/dev/null; then
    local from_props
    from_props="$(extract_runtime_version_from_text "$(git show "${sha}:platforms/android/gradle.properties")")"
    if [[ -n "$from_props" ]]; then
      printf '%s\n' "$from_props"
      return
    fi
  fi
  if git cat-file -e "${sha}:platforms/android/capture-runtime/build.gradle.kts" 2>/dev/null; then
    extract_runtime_version_from_text "$(git show "${sha}:platforms/android/capture-runtime/build.gradle.kts")"
  else
    echo ""
  fi
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
runtime_props="platforms/android/gradle.properties"
apple_podspec="TugboatCaptureRuntime.podspec"
compat_file="docs/releases/compatibility.md"
plugin_gradle="sdks/flutter/packages/tugboat/android/build.gradle"
head_pubspec="sdks/flutter/packages/tugboat/pubspec.yaml"

plugin_pin=""
if [[ -f "$plugin_gradle" ]]; then
  plugin_pin="$(extract_plugin_pin_from_text "$(cat "$plugin_gradle")")"
fi
runtime_now="$(extract_runtime_version "$runtime_props")"
if [[ -z "$runtime_now" ]]; then
  runtime_now="$(extract_runtime_version "$runtime_gradle")"
fi
if [[ -n "$plugin_pin" && -n "$runtime_now" ]]; then
  echo "Flutter capture-runtime pin: $plugin_pin"
  echo "capture-runtime VERSION_NAME: $runtime_now"
  if [[ "$plugin_pin" != "$runtime_now" ]]; then
    higher="$(printf '%s\n%s\n' "$plugin_pin" "$runtime_now" | sort -V | tail -n 1)"
    if [[ "$higher" == "$plugin_pin" ]]; then
      echo "::error::Flutter plugin pins capture-runtime $plugin_pin which is newer than VERSION_NAME $runtime_now."
      exit 1
    fi
    echo "Plugin pin lags VERSION_NAME; a pin PR should follow Maven Central publish."
  fi
fi

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
needs_apple_bump=0
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

extract_apple_version() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo ""
    return
  fi
  grep -E "s\.version[[:space:]]*=" "$file" | head -1 | sed -E "s/.*['\"]([0-9][^'\"]*)['\"].*/\1/"
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

is_apple_public_api() {
  local f="$1"
  case "$f" in
    platforms/apple/Sources/TugboatCaptureRuntime/Internal/*)
      return 1
      ;;
    platforms/apple/Sources/TugboatCaptureRuntime/*)
      return 0
      ;;
    TugboatCaptureRuntime.podspec)
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
  if is_apple_public_api "$f"; then
    needs_apple_bump=1
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
  head_runtime="$(extract_runtime_version "$runtime_props")"
  if [[ -z "$head_runtime" ]]; then
    head_runtime="$(extract_runtime_version "$runtime_gradle")"
  fi
  if [[ -z "$head_runtime" ]]; then
    echo "::error::Could not read capture-runtime version from $runtime_props"
    exit 1
  fi
  base_runtime="$(extract_runtime_version_at "$BASE_SHA")"
  if [[ -n "$base_runtime" ]]; then
    echo "Base runtime version: $base_runtime"
    echo "PR runtime version:   $head_runtime"
    require_greater_version "capture-runtime" "$base_runtime" "$head_runtime"
  else
    echo "Base has no capture-runtime; new artifact $head_runtime (ok)."
  fi
else
  echo "No public runtime API / C ABI changes; skipping capture-runtime version bump."
fi

if [[ "$needs_apple_bump" -eq 1 ]]; then
  if [[ ! -f "$apple_podspec" ]]; then
    echo "::error::$apple_podspec is missing on this branch"
    exit 1
  fi
  head_apple="$(extract_apple_version "$apple_podspec")"
  if [[ -z "$head_apple" ]]; then
    echo "::error::Could not read TugboatCaptureRuntime version from $apple_podspec"
    exit 1
  fi
  if git cat-file -e "${BASE_SHA}:${apple_podspec}" 2>/dev/null; then
    base_file="$(mktemp)"
    git show "${BASE_SHA}:${apple_podspec}" >"$base_file"
    base_apple="$(extract_apple_version "$base_file")"
    rm -f "$base_file"
    if [[ -z "$base_apple" ]]; then
      echo "::error::Could not read TugboatCaptureRuntime version from base $apple_podspec"
      exit 1
    fi
    echo "Base Apple runtime version: $base_apple"
    echo "PR Apple runtime version:   $head_apple"
    require_greater_version "TugboatCaptureRuntime" "$base_apple" "$head_apple"
  else
    echo "Base has no TugboatCaptureRuntime podspec; new artifact $head_apple (ok)."
  fi
else
  echo "No public Apple runtime API changes; skipping TugboatCaptureRuntime version bump."
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

if git diff --name-only "$BASE_SHA" | grep -qx "$plugin_gradle" \
  || git ls-files --others --exclude-standard | grep -qx "$plugin_gradle"; then
  if [[ -z "$plugin_pin" || -z "$runtime_now" ]]; then
    echo "::error::Could not compare Flutter capture-runtime pin to VERSION_NAME."
    exit 1
  fi
  base_pin=""
  if git cat-file -e "${BASE_SHA}:${plugin_gradle}" 2>/dev/null; then
    base_pin="$(extract_plugin_pin_from_text "$(git show "${BASE_SHA}:${plugin_gradle}")")"
  fi
  if [[ "$base_pin" != "$plugin_pin" && "$plugin_pin" != "$runtime_now" ]]; then
    echo "::error::Flutter plugin capture-runtime pin ($plugin_pin) must match VERSION_NAME ($runtime_now) when the pin changes."
    exit 1
  fi
fi

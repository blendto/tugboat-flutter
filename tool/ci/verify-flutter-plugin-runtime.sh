#!/usr/bin/env bash
# Compiles the Flutter plugin's Android code against the pinned
# capture-runtime (from Maven Central) and against the repository's current
# runtime version from .local-maven, so a runtime version bump cannot land
# while the plugin fails to build against it. Run after
# tool/ci/build-android-runtime.sh (or publish-android-runtime-local.sh) has
# published the local AAR.
#
# The example resolves the in-repo runtime by default (see
# example/android/build.gradle.kts); TUGBOAT_PUBLISHED_CAPTURE_RUNTIME=1 makes
# it resolve the plugin's pin instead.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
runtime_version="$(sed -n 's/^VERSION_NAME=//p' "$root/platforms/android/gradle.properties")"
pinned_version="$(sed -n 's/.*com\.gettugboat\.sdk:capture-runtime:\([^"]*\)".*/\1/p' \
  "$root/sdks/flutter/packages/tugboat/android/build.gradle")"
example="$root/sdks/flutter/packages/tugboat/example"

if [[ ! -f "$root/.local-maven/com/gettugboat/sdk/capture-runtime/$runtime_version/capture-runtime-$runtime_version.aar" ]]; then
  echo "::error::capture-runtime $runtime_version is not in .local-maven; run tool/ci/publish-android-runtime-local.sh first."
  exit 1
fi

# Pub runs from the workspace root (AGENTS.md); --config-only writes the
# example's gitignored local.properties and plugin registrant.
(cd "$root" && flutter pub get >/dev/null)
(cd "$example" && flutter build apk --config-only >/dev/null)

# Compiles the plugin and checks the capture-runtime version it resolved.
compile_plugin() {
  local expected="$1" resolved
  resolved="$(cd "$example/android" && ./gradlew -q \
    :tugboat:compileDebugKotlin \
    :tugboat:dependencyInsight --dependency capture-runtime --configuration debugCompileClasspath)"
  resolved="$(grep -m1 -o "com.gettugboat.sdk:capture-runtime:[^ ]*" <<< "$resolved" || true)"
  echo "  resolved $resolved"
  [[ "$resolved" == "com.gettugboat.sdk:capture-runtime:$expected" ]]
}

echo "Plugin against the pinned capture-runtime $pinned_version (Maven Central):"
TUGBOAT_PUBLISHED_CAPTURE_RUNTIME=1 compile_plugin "$pinned_version"

echo "Plugin against the in-repo capture-runtime $runtime_version (.local-maven):"
compile_plugin "$runtime_version"

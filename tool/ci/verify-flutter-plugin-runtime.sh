#!/usr/bin/env bash
# Compiles the Flutter plugin's Android code against the pinned
# capture-runtime (from Maven Central) and against the repository's current
# runtime version from .local-maven, so a runtime version bump cannot land
# while the plugin fails to build against it. Run after
# tool/ci/build-android-runtime.sh has published the local AAR.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
local_maven="$root/.local-maven"
runtime_version="$(sed -n 's/^VERSION_NAME=//p' "$root/platforms/android/gradle.properties")"
example="$root/sdks/flutter/packages/tugboat/example"
init_script="$root/tool/ci/capture-runtime-override.init.gradle"

if [[ ! -d "$local_maven/com/gettugboat/sdk/capture-runtime/$runtime_version" ]]; then
  echo "::error::capture-runtime $runtime_version is not in .local-maven; run tool/ci/build-android-runtime.sh first."
  exit 1
fi

# Pub runs from the workspace root (AGENTS.md); --config-only writes the
# example's gitignored local.properties and plugin registrant.
(cd "$root" && flutter pub get >/dev/null)
(cd "$example" && flutter build apk --config-only >/dev/null)

# Compiles the plugin and prints the capture-runtime version it resolved.
compile_plugin() {
  (cd "$example/android" && ./gradlew -q -I "$init_script" \
    :tugboat:compileDebugKotlin \
    :tugboat:dependencyInsight --dependency capture-runtime --configuration debugCompileClasspath) |
    grep -m1 "com.gettugboat.sdk:capture-runtime:"
}

echo "Plugin against the pinned capture-runtime:"
compile_plugin

echo "Plugin against capture-runtime $runtime_version from .local-maven only:"
TUGBOAT_CAPTURE_RUNTIME_VERSION="$runtime_version" TUGBOAT_LOCAL_MAVEN="$local_maven" \
  compile_plugin | tee /dev/stderr | grep -qF "com.gettugboat.sdk:capture-runtime:$runtime_version"

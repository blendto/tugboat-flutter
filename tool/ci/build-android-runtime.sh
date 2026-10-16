#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
android="$root/platforms/android"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/sdk/android}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
if [[ ! -f "$android/local.properties" ]]; then
  printf 'sdk.dir=%s\n' "$ANDROID_HOME" >"$android/local.properties"
fi
cd "$android"
./gradlew :capture-runtime:test :capture-runtime-test:test :capture-runtime-test:assembleAndroidTest :capture-runtime:assembleRelease :capture-runtime:publishAllPublicationsToLocalCaptureRepository
./gradlew :sample:assembleDebug
# Native host (unpublished): engine JNI build, unit tests, instrumented-test APK.
./gradlew :tugboat-android:test :tugboat-android:assembleRelease :tugboat-android:assembleAndroidTest
# Native SDK sample app (Views + Compose), for emulator device tests against a local collector.
./gradlew :tugboat-sample:testDebugUnitTest :tugboat-sample:assembleDebug
# Compose adapter (unpublished): Robolectric unit tests and the release AAR.
# Its end-to-end tests run in :tugboat-android:test above, on Compose UI 1.8.3.
./gradlew :tugboat-compose:test :tugboat-compose:assembleRelease
# The other end of the tested Compose UI range (1.7.0, BOM 2024.09.00).
./gradlew -Ptugboat.composeBom=2024.09.00 :tugboat-compose:testDebugUnitTest \
  :tugboat-android:testDebugUnitTest --tests 'com.tugboat.android.views.compose.*'
# OkHttp adapter (unpublished): Robolectric + MockWebServer tests on OkHttp
# 5.3.2 and the release AAR, then the tests on the floor (3.14.9) and 4.12.0.
./gradlew :tugboat-okhttp:test :tugboat-okhttp:assembleRelease
./gradlew -Ptugboat.okhttpTest=3.14.9 :tugboat-okhttp:testDebugUnitTest
./gradlew -Ptugboat.okhttpTest=4.12.0 :tugboat-okhttp:testDebugUnitTest

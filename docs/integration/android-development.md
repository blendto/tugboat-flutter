# Android development

The Android Gradle build lives in `platforms/android`.

| Module | Maven | Contents |
| --- | --- | --- |
| `capture-runtime` | `com.gettugboat.sdk:capture-runtime` | Pixel capture runtime (below) |
| `tugboat-android` | `com.gettugboat.sdk:tugboat-android` `0.1.0`, unpublished | Native host for the session engine: `libtugboat_engine.so`, JNI bridge, engine thread, timers, collector HTTP, frame handle table ([README](../../platforms/android/tugboat-android/README.md)) |

The capture runtime:

- Namespace: `com.tugboat.capture.runtime`
- Maven: `com.gettugboat.sdk:capture-runtime` (group is the reverse of
  [gettugboat.com](https://gettugboat.com); `VERSION_NAME` in
  `platforms/android/gradle.properties`)
- Kotlin package: `com.tugboat.capture`
- NDK: `28.2.13676358`
- CMake: `3.22.1`
- Native capture floor: API 24 (Flutter backend below that); window
  capture (`capture(window, …)`, `windowComposite`) needs API 26
- JPEG: platform encoder, quality 80
- Public API golden: `platforms/android/capture-runtime/api.txt`

```sh
bash tool/ci/build-android-runtime.sh
```

That script unit-tests the runtime, compiles the instrumented tests, builds
the release AAR, publishes it to `.local-maven/`, and builds the sample once
the AAR exists. Run the instrumented tests with
`./gradlew :capture-runtime-test:connectedAndroidTest` on a device or
emulator; CI runs them on API 26 and API 34 emulators. After a public
Kotlin or C ABI change, bump `VERSION_NAME` and regenerate `api.txt`:

```sh
python3 tool/ci/dump-android-runtime-api.py > platforms/android/capture-runtime/api.txt
```

Hosted publication (GitHub Packages, then Maven Central) is documented in
[release process](../releases/process.md).

The Flutter plugin at `sdks/flutter/packages/tugboat/android` depends on
Maven Central `com.gettugboat.sdk:capture-runtime:0.1.0` and wraps it behind
the Pigeon `NativeCaptureHostApi`. Changing `CaptureRuntime` for a Flutter
build requires publishing a new AAR version and bumping that coordinate.
Do not log pixel or JPEG data.

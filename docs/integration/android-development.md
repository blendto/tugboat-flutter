# Android development

The capture runtime lives in `platforms/android`.

- Namespace: `com.tugboat.capture.runtime`
- Maven: `com.gettugboat.sdk:capture-runtime` (group is the reverse of
  [gettugboat.com](https://gettugboat.com); `VERSION_NAME` in
  `platforms/android/gradle.properties`)
- Kotlin package: `com.tugboat.capture`
- NDK: `28.2.13676358`
- CMake: `3.22.1`
- Native capture floor: API 24 (Flutter backend below that)
- JPEG: platform encoder, quality 80
- Public API golden: `platforms/android/capture-runtime/api.txt`

```sh
bash tool/ci/build-android-runtime.sh
```

That script unit-tests the runtime, builds the release AAR, publishes it to
`.local-maven/`, and builds the sample once the AAR exists. After a public
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

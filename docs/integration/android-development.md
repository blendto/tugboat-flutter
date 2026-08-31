# Android development

The capture runtime lives in `platforms/android`.

- Namespace: `com.tugboat.capture.runtime`
- Maven: `com.tugboat.sdk:capture-runtime:0.1.0`
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
Kotlin or C ABI change, bump the Maven version and regenerate `api.txt`:

```sh
python3 tool/ci/dump-android-runtime-api.py > platforms/android/capture-runtime/api.txt
```

The Flutter plugin at `sdks/flutter/packages/tugboat/android` wraps
`CaptureRuntime` behind the Pigeon `NativeCaptureHostApi`. Do not log pixel
or JPEG data.

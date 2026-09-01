# Android capture runtime

Maven artifact `com.tugboat.sdk:capture-runtime:0.1.0`.
Namespace `com.tugboat.capture.runtime`. Kotlin runtime plus the C++ core
compiled into an AAR (`arm64-v8a`, `armeabi-v7a`, `x86_64`).

Native capture requires API 24. Older devices report `unsupportedApi`.
The first source is `PixelCopy` of `FlutterSurfaceView`. TextureView and
hybrid composition return `unsupportedRenderMode`.

## Build

From `platforms/android` (needs Android SDK, NDK `28.2.13676358`, CMake
`3.22.1`):

```sh
./gradlew :capture-runtime:test
./gradlew :capture-runtime:assembleRelease
./gradlew :capture-runtime:publish
```

`publish` writes
`.local-maven/com/tugboat/sdk/capture-runtime/0.1.0/` at the repository
root (gitignored). After that:

```sh
./gradlew :sample:assembleDebug
```

The sample resolves `com.tugboat.sdk:capture-runtime:0.1.0` from that
repository, not from `project()`.

`connectedAndroidTest` for lifecycle and render-mode tests needs a device
or emulator. API 24 vs recent, rotation, and activity-recreation tests wait
on a Flutter `FlutterSurfaceView` fixture (Phase 6).

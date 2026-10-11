# Android capture runtime

Maven artifact `com.gettugboat.sdk:capture-runtime:0.1.0` (group follows
[gettugboat.com](https://gettugboat.com)). Android namespace
`com.tugboat.capture.runtime`. Kotlin runtime plus the C++ core
compiled into an AAR (`arm64-v8a`, `armeabi-v7a`, `x86_64`).

`VERSION_NAME` `0.2.0` is unpublished; it adds window capture.

Two `PixelCopy` sources share one queue and pipeline:

- `capture(view, …)`: the active `FlutterSurfaceView` (API 24+), coverage
  `engineSurface`. TextureView and hybrid composition return
  `unsupportedRenderMode`.
- `capture(window, …)`: a whole app `Window` (API 26+), coverage
  `windowComposite`. `FLAG_SECURE` windows return `secureWindow` and are
  never copied. Separate `SurfaceView` / `TextureView` layers are not in the
  copy.

Older devices report `unsupportedApi`.

## Build

From `platforms/android` (needs Android SDK, NDK `28.2.13676358`, CMake
`3.22.1`):

```sh
./gradlew :capture-runtime:test
./gradlew :capture-runtime:assembleRelease
./gradlew :capture-runtime:publishAllPublicationsToLocalCaptureRepository
```

Or from the repository root: `bash tool/ci/build-android-runtime.sh`.

Local publish writes
`.local-maven/com/gettugboat/sdk/capture-runtime/<version>/` at the repository
root (gitignored). After that:

```sh
./gradlew :sample:assembleDebug
```

The sample resolves `com.gettugboat.sdk:capture-runtime` from that repository,
not from `project()`. Version is `VERSION_NAME` in `gradle.properties`.

`:capture-runtime-test:connectedAndroidTest` (lifecycle, render-mode, and
window capture of a solid-colour activity with a mask) needs a device or
emulator. API 24 vs recent, rotation, and activity-recreation tests wait
on a Flutter `FlutterSurfaceView` fixture (Phase 6).

## Hosted Maven

Merging a version bump to `main` tags `capture-runtime-v<version>` and
publishes GitHub Packages. Maven Central is a second job that runs when
Central Portal secrets are configured. See
[release process](../../docs/releases/process.md).

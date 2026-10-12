# Android capture runtime

Maven artifact `com.gettugboat.sdk:capture-runtime:0.1.0` (group follows
[gettugboat.com](https://gettugboat.com)). Android namespace
`com.tugboat.capture.runtime`. Kotlin runtime plus the C++ core
compiled into an AAR (`arm64-v8a`, `armeabi-v7a`, `x86_64`).

Two `PixelCopy` sources share one queue and pipeline:

- `capture(view, …)`: the active `FlutterSurfaceView` (API 24+), coverage
  `engineSurface`. TextureView and hybrid composition return
  `unsupportedRenderMode`.
- `capture(window, …)`: one app `Window`'s surface (API 26+), coverage
  `windowComposite`. `TextureView` is in the copy; `SurfaceView` layers and
  other windows (dialogs, popups, the IME) are not. A window flagged
  `FLAG_SECURE` is never copied (`secureWindow`), and the copy comes from a
  frame committed after that check.

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
emulator. CI runs it on API 26 and API 34 emulators
(`.github/workflows/android-runtime-device.yml`). API 24 vs recent, rotation, and activity-recreation tests wait
on a Flutter `FlutterSurfaceView` fixture (Phase 6).

## Native SDK and sample

`tugboat-android` (the native Android SDK on the session engine) and its
sample app `tugboat-sample` live in this build too; they use `capture-runtime`
as a project dependency and need no local Maven. See
[tugboat-android/README.md](tugboat-android/README.md) and
[tugboat-sample/README.md](tugboat-sample/README.md) (device-test script).

## Hosted Maven

Merging a version bump to `main` tags `capture-runtime-v<version>` and
publishes GitHub Packages. Maven Central is a second job that runs when
Central Portal secrets are configured. See
[release process](../../docs/releases/process.md).

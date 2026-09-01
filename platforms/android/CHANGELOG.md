# Android capture-runtime

## 0.1.0

Initial local Maven artifact `com.tugboat.sdk:capture-runtime:0.1.0`.

- `PixelCopy` of `FlutterSurfaceView` (API 24+).
- Portable C++ core for masks, dHash, and skip.
- Platform JPEG quality 80 and SHA-256 of the JPEG.
- Public API recorded in `api.txt`.

Not published to Maven Central. Flutter 0.8.13 compiles this from monorepo
sources. Local Maven (`.local-maven` after
`tool/ci/build-android-runtime.sh`) is only for the standalone native Android
sample.

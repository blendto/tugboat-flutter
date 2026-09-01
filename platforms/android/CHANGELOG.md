# Android capture-runtime

## 0.1.0

Initial Maven artifact `com.gettugboat.sdk:capture-runtime:0.1.0`.

- `PixelCopy` of `FlutterSurfaceView` (API 24+).
- Portable C++ core for masks, dHash, and skip.
- Platform JPEG quality 80 and SHA-256 of the JPEG.
- Public API recorded in `api.txt`.

GitHub Actions publishes this coordinate to GitHub Packages on tag
`capture-runtime-v0.1.0`. Maven Central waits on namespace verification.
Flutter 0.8.13 still compiles this from monorepo sources. Local Maven
(`.local-maven` after `tool/ci/build-android-runtime.sh`) is only for the
standalone native Android sample.

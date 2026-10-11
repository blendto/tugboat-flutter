# Android capture-runtime

## 0.2.0

Unpublished. Additive; the `FlutterSurfaceView` path is unchanged.

- `CaptureRuntime.capture(window, request, onComplete)`: `PixelCopy` of an
  app `Window` (API 26+, `MIN_WINDOW_API`; below that `UnsupportedApi`).
  Reports coverage `WindowComposite`. Masks are normalized to the window's
  decor view. Separate `SurfaceView` / `TextureView` layers are not in the
  copy; callers mask them fail-closed.
- `CaptureStatus.SecureWindow`: a window with `FLAG_SECURE` is never copied.
  The result has no frame and no coverage.
- `CaptureCoverage.WindowComposite`.
- View and window captures share one queue and one pipeline (cancellation,
  disposal, mask mapping, C++ mask fill + dHash, JPEG q80, SHA-256, timings).

The Flutter plugin still pins `0.1.0`. Its exhaustive `when` over
`CaptureStatus` and `CaptureCoverage` needs `SecureWindow` and
`WindowComposite` branches before it can compile against `0.2.0`.

## 0.1.0

Initial Maven artifact `com.gettugboat.sdk:capture-runtime:0.1.0`.

- `PixelCopy` of `FlutterSurfaceView` (API 24+).
- Portable C++ core for masks, dHash, and skip.
- Platform JPEG quality 80 and SHA-256 of the JPEG.
- Public API recorded in `api.txt`.

GitHub Actions publishes this coordinate to GitHub Packages on tag
`capture-runtime-v0.1.0` and to Maven Central. Flutter `0.8.14` depends on
that hosted coordinate. Local Maven (`.local-maven` after
`tool/ci/build-android-runtime.sh`) is only for the standalone native Android
sample.

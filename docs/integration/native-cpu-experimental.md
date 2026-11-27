# Experimental native CPU screenshot capture

Status: experimental opt-in, Android PixelCopy and iOS engine-surface CPU
paths

`TugboatScreenshotCaptureBackend.flutterRepaintBoundary` remains the default.
Set `screenshotCaptureBackend` to
`TugboatScreenshotCaptureBackend.nativeCpuExperimental` only when you intend
to exercise the native CPU backend (Android `PixelCopy` of the engine
surface, or iOS rendering of the live Flutter layer).

The native path:

- Captures the Flutter engine `SurfaceView` with `PixelCopy` (Android) or
  the live Flutter layer with `CALayer.render(in:)` (iOS)
- Applies privacy masks and dHash in the portable C++ core
- Encodes JPEG on the platform (quality 80)
- Returns masked JPEG bytes and bounded metadata to Dart

It automatically falls back to `RepaintBoundary` when the runtime is
unsupported, the surface is unavailable, PixelCopy / Apple layer capture
fails, processing fails, or the native timeout fires. Cancellation and
disposal do not fall back. Native and Flutter results are never published
for the same request.

Raw pixels never cross the platform channel. Do not enable this backend in
production until the comparison contract in
[cpu-capture-baseline.md](../performance/cpu-capture-baseline.md) and the
privacy rules in
[native-capture-contracts.md](../architecture/native-capture-contracts.md)
hold for the target app. Physical-device privacy and performance sign-off is
an internal lab gate.

## When the Android native path runs

On Android the native path copies the Flutter engine's `FlutterSurfaceView`.
It never copies the app window, so whether it runs depends on how the
Flutter view renders:

- **Surface render mode** (the default for `FlutterActivity`,
  `FlutterFragment` and `FlutterView`): the native path runs.
- **Texture render mode** (`RenderMode.texture`, for example for a
  transparent Flutter background): there is no `FlutterSurfaceView`, so
  every request falls back with `unsupportedRenderMode`. After three
  fallbacks in a row native capture turns off for the rest of the session.
  Frames are correct, but they cost as much as the default backend.
- **Hybrid composition platform views** (`initExpensiveAndroidView`, or a
  plugin option such as `useAndroidViewSurface` or
  `displayWithHybridComposition`): while one is on screen, Flutter pauses
  the `FlutterSurfaceView` and draws into a `FlutterImageView` instead. The
  runtime does not detect this switch and still copies the paused surface.
  The copy either fails and falls back, or returns the last frame drawn
  before the switch while the masks describe the current screen. Do not
  enable the native backend in apps that show hybrid composition platform
  views. Platform views shown with texture
  layer hybrid composition (the default for `AndroidView`) do not cause this.
  On every backend, the default mask level does not mask platform views yet;
  wrap them in `TugboatSensitive` (see the per-adapter differences in
  [native-capture-contracts.md](../architecture/native-capture-contracts.md)).
- **Add-to-app** (a Flutter screen inside a native Android app): the same
  rules apply to the embedded `FlutterView`. The plugin captures the first
  `FlutterView` in the current activity.

### Add-to-app and the native SDKs

The native Android and Swift SDKs do not look inside a Flutter view. They
mask its whole bounds as an opaque surface (a `SurfaceView` or `TextureView`
on Android, a `CAMetalLayer` on iOS), and taps inside it carry no Flutter
widget identity. To replay the Flutter screens of an add-to-app host, the
Flutter module must run the Tugboat Flutter SDK. The Flutter and native
SDKs then record separate sessions; nothing links them.

## Requirements and status

The Apple plugin requires iOS 15 (same floor as `TugboatCaptureRuntime`).
Native capture stays opt-in (`nativeCpuExperimental`). Physical device privacy
and performance rows are still open before making native capture the default.

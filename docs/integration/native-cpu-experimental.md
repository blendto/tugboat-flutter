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

The Apple plugin reports native capture as supported on iOS 15+. The plugin
deployment target remains iOS 12 so default `RepaintBoundary` apps are not
forced onto iOS 15. Physical device privacy and performance rows are still
open. Do not publish the Apple 0.1.0 CocoaPod yet.

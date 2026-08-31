# Experimental native CPU screenshot capture

Status: experimental opt-in, Android CPU path only

`TugboatScreenshotCaptureBackend.flutterRepaintBoundary` remains the default.
Set `screenshotCaptureBackend` to
`TugboatScreenshotCaptureBackend.nativeCpuExperimental` only when you intend
to exercise the native Android CPU backend.

The native path:

- Captures the Flutter engine `SurfaceView` with `PixelCopy`
- Applies privacy masks and dHash in the portable C++ core
- Encodes JPEG on the platform (quality 80)
- Returns masked JPEG bytes and bounded metadata to Dart

It automatically falls back to `RepaintBoundary` when the runtime is
unsupported, the surface is unavailable, PixelCopy fails, processing fails, or
the native timeout fires. Cancellation and disposal do not fall back. Native
and Flutter results are never published for the same request.

Raw pixels never cross the platform channel. Do not enable this backend in
production until the privacy and performance gates in
[cpu-capture-baseline.md](../performance/cpu-capture-baseline.md) pass.

The Apple plugin currently reports native capture as unavailable.

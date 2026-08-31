/// Screenshot pixel-acquisition backend.
///
/// [flutterRepaintBoundary] is the supported default. It reads pixels through
/// Flutter's `RepaintBoundary.toImage` path.
///
/// [nativeCpuExperimental] is an opt-in Android CPU capture path. It is
/// experimental: keep [flutterRepaintBoundary] in production until native
/// privacy and performance gates pass. Unsupported devices and native
/// failures fall back to [flutterRepaintBoundary] for that request only.
/// Cancellation does not fall back. Native and Flutter results are never
/// published together for one request.
enum TugboatScreenshotCaptureBackend {
  flutterRepaintBoundary,
  nativeCpuExperimental,
}

/// Bounded native/Flutter backend metadata for capture diagnostics.
class ScreenshotBackendTrace {
  const ScreenshotBackendTrace({
    required this.requested,
    required this.resolved,
    this.coverage,
    this.fallbackReason,
    this.renderMode,
    this.surfaceCopyMicros = 0,
    this.maskFillMicros = 0,
    this.dHashMicros = 0,
    this.jpegMicros = 0,
    this.sha256Micros = 0,
    this.pixelReadbackMicros = 0,
    this.platformChannelMicros = 0,
  });

  const ScreenshotBackendTrace.flutter({
    this.requested = TugboatScreenshotCaptureBackend.flutterRepaintBoundary,
    this.fallbackReason,
  }) : resolved = TugboatScreenshotCaptureBackend.flutterRepaintBoundary,
       coverage = null,
       renderMode = null,
       surfaceCopyMicros = 0,
       maskFillMicros = 0,
       dHashMicros = 0,
       jpegMicros = 0,
       sha256Micros = 0,
       pixelReadbackMicros = 0,
       platformChannelMicros = 0;

  final TugboatScreenshotCaptureBackend requested;
  final TugboatScreenshotCaptureBackend resolved;
  final String? coverage;
  final String? fallbackReason;
  final String? renderMode;
  final int surfaceCopyMicros;
  final int maskFillMicros;
  final int dHashMicros;
  final int jpegMicros;
  final int sha256Micros;
  final int pixelReadbackMicros;
  final int platformChannelMicros;

  Map<String, Object?> toDiagnosticFields() => {
    'requestedBackend': requested.name,
    'resolvedBackend': resolved.name,
    if (coverage != null) 'coverage': coverage,
    if (fallbackReason != null) 'fallbackReason': fallbackReason,
    if (renderMode != null) 'renderMode': renderMode,
    if (surfaceCopyMicros != 0) 'surfaceCopyMicros': surfaceCopyMicros,
    if (maskFillMicros != 0) 'maskFillMicros': maskFillMicros,
    if (dHashMicros != 0) 'dHashMicros': dHashMicros,
    if (jpegMicros != 0) 'jpegMicros': jpegMicros,
    if (sha256Micros != 0) 'sha256Micros': sha256Micros,
    if (pixelReadbackMicros != 0) 'pixelReadbackMicros': pixelReadbackMicros,
    if (platformChannelMicros != 0)
      'platformChannelMicros': platformChannelMicros,
  };
}

import 'native_capture.g.dart';
import 'native_capture_client.dart';
import 'screenshot_capture_backend.dart';
import 'screenshot_pixel_source.dart';

class NativeCpuExperimentalPixelSource implements ScreenshotPixelSource {
  NativeCpuExperimentalPixelSource({
    required this.client,
    required this.fallback,
  });

  final NativeCaptureClient client;
  final ScreenshotPixelSource fallback;

  @override
  Future<ScreenshotPixelAcquisition> acquire(
    ScreenshotPixelRequest request,
  ) async {
    if (client.isDisabled) {
      return fallback.acquire(
        request.withFallback(client.lastFallbackReason ?? 'processingFailed'),
      );
    }
    final caps = await client.capabilities();
    if (!caps.nativeCaptureSupported) {
      return fallback.acquire(request.withFallback('unsupportedApi'));
    }
    final channelClock = Stopwatch()..start();
    final reply = await client.capture(_requestFor(request));
    channelClock.stop();
    return _resolve(request, reply, channelClock.elapsedMicroseconds);
  }

  Future<ScreenshotPixelAcquisition> _resolve(
    ScreenshotPixelRequest request,
    NativeCaptureResult reply,
    int platformChannelMicros,
  ) async {
    switch (reply.status) {
      case NativeCaptureStatus.ok:
        return _nativeFrame(
          request,
          reply,
          platformChannelMicros,
          ScreenshotPixelDisposition.captured,
        );
      case NativeCaptureStatus.skippedByDHash:
        return _nativeFrame(
          request,
          reply,
          platformChannelMicros,
          ScreenshotPixelDisposition.skipped,
        );
      case NativeCaptureStatus.cancelled:
      case NativeCaptureStatus.disposed:
        return ScreenshotPixelAcquisition(
          disposition: ScreenshotPixelDisposition.cancelled,
          failure: ScreenshotCaptureFailureKind.cancelled,
          trace: _nativeTrace(request, reply, platformChannelMicros),
        );
      case NativeCaptureStatus.unsupportedApi:
      case NativeCaptureStatus.unsupportedRenderMode:
      case NativeCaptureStatus.surfaceUnavailable:
      case NativeCaptureStatus.timeout:
      case NativeCaptureStatus.pixelCopyFailed:
      case NativeCaptureStatus.processingFailed:
        return fallback.acquire(request.withFallback(reply.status.name));
    }
  }

  NativeCaptureRequest _requestFor(ScreenshotPixelRequest request) {
    return NativeCaptureRequest(
      requestId: client.allocateRequestId(),
      pixelWidth: request.pixelWidth,
      pixelHeight: request.pixelHeight,
      force: request.force,
      lastDHash: request.lastDHash,
      masks: normalizeMaskRects(request.maskRects, request.logicalSize),
    );
  }

  ScreenshotPixelAcquisition _nativeFrame(
    ScreenshotPixelRequest request,
    NativeCaptureResult reply,
    int platformChannelMicros,
    ScreenshotPixelDisposition disposition,
  ) {
    return ScreenshotPixelAcquisition(
      disposition: disposition,
      bytes: reply.jpeg,
      contentHash: disposition == ScreenshotPixelDisposition.skipped
          ? ''
          : reply.contentHash,
      dHash: reply.dHash,
      width: reply.width,
      height: reply.height,
      masked: request.maskRects.isNotEmpty,
      skippedByDHash: disposition == ScreenshotPixelDisposition.skipped,
      captureMicros: 0,
      encodeMicros: _encodeMicros(reply.timings, platformChannelMicros),
      trace: _nativeTrace(request, reply, platformChannelMicros),
    );
  }

  int _encodeMicros(NativeCaptureTimings timings, int platformChannelMicros) {
    return timings.surfaceCopyMicros +
        timings.maskFillMicros +
        timings.dHashMicros +
        timings.jpegMicros +
        timings.sha256Micros +
        platformChannelMicros;
  }

  ScreenshotBackendTrace _nativeTrace(
    ScreenshotPixelRequest request,
    NativeCaptureResult reply,
    int platformChannelMicros,
  ) {
    return ScreenshotBackendTrace(
      requested: request.requestedBackend,
      resolved: TugboatScreenshotCaptureBackend.nativeCpuExperimental,
      coverage: reply.coverage?.name,
      renderMode: reply.renderMode.name,
      surfaceCopyMicros: reply.timings.surfaceCopyMicros,
      maskFillMicros: reply.timings.maskFillMicros,
      dHashMicros: reply.timings.dHashMicros,
      jpegMicros: reply.timings.jpegMicros,
      sha256Micros: reply.timings.sha256Micros,
      platformChannelMicros: platformChannelMicros,
    );
  }

  @override
  void resetSession() => client.resetSession();

  @override
  Future<void> dispose() async {
    await client.dispose();
    await fallback.dispose();
  }
}

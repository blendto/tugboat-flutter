import 'dart:ui' as ui;

import 'screenshot_capture_backend.dart';
import 'screenshot_encode.dart';
import 'screenshot_pixel_source.dart';

class FlutterRepaintBoundaryPixelSource implements ScreenshotPixelSource {
  FlutterRepaintBoundaryPixelSource(this._encoder);

  final ScreenshotEncoder _encoder;

  @override
  Future<ScreenshotPixelAcquisition> acquire(
    ScreenshotPixelRequest request,
  ) async {
    final readbackClock = Stopwatch()..start();
    final image = await _readback(request);
    readbackClock.stop();
    if (image == null) {
      return _failed(
        request,
        captureWasCancelled(request.isCurrent)
            ? ScreenshotCaptureFailureKind.cancelled
            : ScreenshotCaptureFailureKind.readbackFailed,
      );
    }
    if (captureWasCancelled(request.isCurrent)) {
      image.dispose();
      return _failed(request, ScreenshotCaptureFailureKind.cancelled);
    }
    try {
      return await _encode(request, image, readbackClock.elapsedMicroseconds);
    } finally {
      image.dispose();
    }
  }

  Future<ui.Image?> _readback(ScreenshotPixelRequest request) async {
    try {
      return await request.boundary.toImage(
        pixelRatio: request.capturePixelRatio,
      );
    } catch (_) {
      return null;
    }
  }

  Future<ScreenshotPixelAcquisition> _encode(
    ScreenshotPixelRequest request,
    ui.Image image,
    int captureMicros,
  ) async {
    final encodeClock = Stopwatch()..start();
    try {
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (byteData == null) {
        return _failed(request, ScreenshotCaptureFailureKind.encodingFailed);
      }
      final encoded = await _encoder.encode(
        flutterEncodeInput(
          rgba: byteData.buffer.asUint8List(),
          width: image.width,
          height: image.height,
          maskRects: request.maskRects,
          capturePixelRatio: request.capturePixelRatio,
          lastDHash: request.lastDHash,
          force: request.force,
        ),
      );
      encodeClock.stop();
      return ScreenshotPixelAcquisition(
        disposition: encoded.skippedByDHash
            ? ScreenshotPixelDisposition.skipped
            : ScreenshotPixelDisposition.captured,
        bytes: encoded.bytes,
        contentHash: encoded.contentHash,
        dHash: encoded.dHash,
        width: image.width,
        height: image.height,
        masked: request.maskRects.isNotEmpty,
        captureMicros: captureMicros,
        encodeMicros: encodeClock.elapsedMicroseconds,
        skippedByDHash: encoded.skippedByDHash,
        trace: ScreenshotBackendTrace.flutter(
          requested: request.requestedBackend,
          fallbackReason: request.fallbackReason,
        ),
      );
    } catch (_) {
      return _failed(request, ScreenshotCaptureFailureKind.encodingFailed);
    }
  }

  ScreenshotPixelAcquisition _failed(
    ScreenshotPixelRequest request,
    ScreenshotCaptureFailureKind failure,
  ) {
    return ScreenshotPixelAcquisition(
      disposition: failure == ScreenshotCaptureFailureKind.cancelled
          ? ScreenshotPixelDisposition.cancelled
          : ScreenshotPixelDisposition.failed,
      failure: failure,
      trace: ScreenshotBackendTrace.flutter(
        requested: request.requestedBackend,
        fallbackReason: request.fallbackReason,
      ),
    );
  }

  @override
  void resetSession() {}

  @override
  Future<void> dispose() => _encoder.dispose();
}

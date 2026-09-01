import 'dart:typed_data';

import 'package:flutter/rendering.dart';

import 'native_capture.g.dart';
import 'screenshot_capture_backend.dart';
import 'screenshot_encode.dart';

enum ScreenshotPixelDisposition { captured, skipped, cancelled, failed }

class ScreenshotPixelRequest {
  const ScreenshotPixelRequest({
    required this.boundary,
    required this.capturePixelRatio,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.logicalSize,
    required this.maskRects,
    required this.lastDHash,
    required this.force,
    required this.requestedBackend,
    this.isCurrent,
    this.fallbackReason,
  });

  final RenderRepaintBoundary boundary;
  final double capturePixelRatio;
  final int pixelWidth;
  final int pixelHeight;
  final Size logicalSize;
  final List<Rect> maskRects;
  final String lastDHash;
  final bool force;
  final TugboatScreenshotCaptureBackend requestedBackend;
  final bool Function()? isCurrent;
  final String? fallbackReason;

  ScreenshotPixelRequest withFallback(String reason) => ScreenshotPixelRequest(
    boundary: boundary,
    capturePixelRatio: capturePixelRatio,
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight,
    logicalSize: logicalSize,
    maskRects: maskRects,
    lastDHash: lastDHash,
    force: force,
    requestedBackend: requestedBackend,
    isCurrent: isCurrent,
    fallbackReason: reason,
  );
}

class ScreenshotPixelAcquisition {
  const ScreenshotPixelAcquisition({
    required this.disposition,
    this.bytes,
    this.contentHash = '',
    this.dHash,
    this.width = 0,
    this.height = 0,
    this.masked = false,
    this.captureMicros = 0,
    this.encodeMicros = 0,
    this.skippedByDHash = false,
    this.failure,
    required this.trace,
  });

  final ScreenshotPixelDisposition disposition;
  final Uint8List? bytes;
  final String contentHash;
  final String? dHash;
  final int width;
  final int height;
  final bool masked;
  final int captureMicros;
  final int encodeMicros;
  final bool skippedByDHash;
  final ScreenshotCaptureFailureKind? failure;
  final ScreenshotBackendTrace trace;
}

enum ScreenshotCaptureFailureKind { readbackFailed, encodingFailed, cancelled }

/// Pixel acquisition for one prepared capture. Scheduling stays in the capturer.
abstract class ScreenshotPixelSource {
  Future<ScreenshotPixelAcquisition> acquire(ScreenshotPixelRequest request);

  void resetSession();

  Future<void> dispose();
}

Float64List scaledMaskBuffer(List<Rect> maskRects, double capturePixelRatio) {
  final scaledMasks = Float64List(maskRects.length * 4);
  for (var i = 0; i < maskRects.length; i++) {
    final rect = maskRects[i];
    final base = i * 4;
    scaledMasks[base] = rect.left * capturePixelRatio;
    scaledMasks[base + 1] = rect.top * capturePixelRatio;
    scaledMasks[base + 2] = rect.right * capturePixelRatio;
    scaledMasks[base + 3] = rect.bottom * capturePixelRatio;
  }
  return scaledMasks;
}

List<NativeCaptureMask> normalizeMaskRects(List<Rect> masks, Size logicalSize) {
  if (logicalSize.width <= 0 || logicalSize.height <= 0) {
    return const <NativeCaptureMask>[];
  }
  final out = <NativeCaptureMask>[];
  for (final rect in masks) {
    if (rect.width <= 0 || rect.height <= 0) continue;
    out.add(
      NativeCaptureMask(
        x: rect.left / logicalSize.width,
        y: rect.top / logicalSize.height,
        width: rect.width / logicalSize.width,
        height: rect.height / logicalSize.height,
      ),
    );
  }
  return out;
}

bool captureWasCancelled(bool Function()? isCurrent) =>
    isCurrent != null && !isCurrent();

ScreenshotEncodeInput flutterEncodeInput({
  required Uint8List rgba,
  required int width,
  required int height,
  required List<Rect> maskRects,
  required double capturePixelRatio,
  required String lastDHash,
  required bool force,
}) {
  return ScreenshotEncodeInput(
    rgba: rgba,
    width: width,
    height: height,
    maskRects: scaledMaskBuffer(maskRects, capturePixelRatio),
    lastDHash: lastDHash.isEmpty ? null : lastDHash,
    force: force,
  );
}

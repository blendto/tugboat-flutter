import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'perceptual_hash.dart';

/// JPEG quality for emitted frames. Screenshots are photo-heavy once masking
/// is relaxed, where JPEG is ~5x smaller than PNG at comparable legibility.
const int screenshotJpegQuality = 80;

/// Encoded JPEG bytes plus hashes used for coalesce / session dedup.
class ScreenshotEncodeResult {
  const ScreenshotEncodeResult({
    required this.bytes,
    required this.contentHash,
    this.dHash,
    this.skippedByDHash = false,
  });

  final Uint8List bytes;
  final String contentHash;
  final String? dHash;
  final bool skippedByDHash;
}

/// RGBA frame plus encode options passed to [ScreenshotEncoder].
class ScreenshotEncodeInput {
  const ScreenshotEncodeInput({
    required this.rgba,
    required this.width,
    required this.height,
    this.maskRects,
    this.lastDHash,
    this.force = false,
  });

  final Uint8List rgba;
  final int width;
  final int height;

  /// Pixel-space mask rectangles as flat `[left, top, right, bottom, ...]`.
  final Float64List? maskRects;
  final String? lastDHash;
  final bool force;

  Float64List get maskRectsOrEmpty => maskRects ?? Float64List(0);
}

/// Dark fill used for masked regions (matches the previous canvas mask color).
const int _maskFillR = 0x1a;
const int _maskFillG = 0x1a;
const int _maskFillB = 0x1a;
const int _maskFillA = 0xff;

void applyMaskRectsInPlace({
  required Uint8List rgba,
  required int width,
  required int height,
  required Float64List maskRects,
}) {
  if (maskRects.isEmpty) return;
  for (var i = 0; i + 3 < maskRects.length; i += 4) {
    final left = maskRects[i].floor().clamp(0, width);
    final top = maskRects[i + 1].floor().clamp(0, height);
    final right = maskRects[i + 2].ceil().clamp(0, width);
    final bottom = maskRects[i + 3].ceil().clamp(0, height);
    if (right <= left || bottom <= top) continue;
    for (var y = top; y < bottom; y++) {
      var offset = (y * width + left) * 4;
      for (var x = left; x < right; x++) {
        rgba[offset] = _maskFillR;
        rgba[offset + 1] = _maskFillG;
        rgba[offset + 2] = _maskFillB;
        rgba[offset + 3] = _maskFillA;
        offset += 4;
      }
    }
  }
}

/// Pure encode path: mask fills → dHash (Hamming≤2) → optional JPEG → SHA-256.
ScreenshotEncodeResult encodeScreenshotRgba(ScreenshotEncodeInput input) {
  final rgba = input.rgba;
  final maskRects = input.maskRects;
  if (maskRects != null && maskRects.isNotEmpty) {
    applyMaskRectsInPlace(
      rgba: rgba,
      width: input.width,
      height: input.height,
      maskRects: maskRects,
    );
  }
  final dHash = computeDHashFromRgba(rgba, input.width, input.height);
  if (!input.force && dHashVisuallyMatches(input.lastDHash, dHash)) {
    return ScreenshotEncodeResult(
      bytes: Uint8List(0),
      contentHash: '',
      dHash: dHash,
      skippedByDHash: true,
    );
  }
  final image = img.Image.fromBytes(
    width: input.width,
    height: input.height,
    bytes: rgba.buffer,
    bytesOffset: rgba.offsetInBytes,
    rowStride: input.width * 4,
    order: img.ChannelOrder.rgba,
  );
  final jpeg = Uint8List.fromList(
    img.encodeJpg(image, quality: screenshotJpegQuality),
  );
  return ScreenshotEncodeResult(
    bytes: jpeg,
    contentHash: sha256.convert(jpeg).toString(),
    dHash: dHash.isEmpty ? null : dHash,
  );
}

/// Encodes screenshot RGBA off the UI thread or inline for tests.
abstract class ScreenshotEncoder {
  Future<ScreenshotEncodeResult> encode(ScreenshotEncodeInput input);

  Future<void> dispose();
}

/// Runs [encodeScreenshotRgba] on the calling isolate (for widget tests).
class InlineScreenshotEncoder implements ScreenshotEncoder {
  @override
  Future<ScreenshotEncodeResult> encode(ScreenshotEncodeInput input) async {
    return encodeScreenshotRgba(input);
  }

  @override
  Future<void> dispose() => Future<void>.value();
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:tugboat/src/screenshot_encode_isolate.dart';

Uint8List _solidRed() {
  final rgba = Uint8List(4 * 8 * 8);
  for (var i = 0; i < rgba.length; i += 4) {
    rgba[i] = 255;
    rgba[i + 3] = 255;
  }
  return rgba;
}

void main() {
  test('persistent encode isolate returns jpeg bytes and content hash', () async {
    final worker = ScreenshotEncodeIsolate();
    addTearDown(worker.dispose);
    final first = await worker
        .encode(rgba: _solidRed(), width: 8, height: 8)
        .timeout(const Duration(seconds: 10));
    final second = await worker
        .encode(rgba: _solidRed(), width: 8, height: 8)
        .timeout(const Duration(seconds: 10));
    expect(first.bytes, isNotEmpty);
    expect(first.contentHash, isNotEmpty);
    expect(second.contentHash, first.contentHash);
  });

  test('encode isolate applies mask fills before jpeg encoding', () async {
    final worker = ScreenshotEncodeIsolate();
    addTearDown(worker.dispose);
    final masked = await worker
        .encode(
          rgba: _solidRed(),
          width: 8,
          height: 8,
          maskRects: Float64List.fromList([0, 0, 4, 4]),
        )
        .timeout(const Duration(seconds: 10));
    final decoded = img.decodeJpg(masked.bytes)!;
    final maskedPixel = decoded.getPixel(1, 1);
    final unmaskedPixel = decoded.getPixel(6, 6);
    expect(maskedPixel.r.toInt(), lessThan(80));
    expect(unmaskedPixel.r.toInt(), greaterThan(200));
  });

  test('encode isolate skips jpeg when masked dHash matches', () async {
    final worker = ScreenshotEncodeIsolate();
    addTearDown(worker.dispose);
    final first = await worker
        .encode(rgba: _solidRed(), width: 8, height: 8)
        .timeout(const Duration(seconds: 10));
    final second = await worker
        .encode(
          rgba: _solidRed(),
          width: 8,
          height: 8,
          lastDHash: first.dHash,
        )
        .timeout(const Duration(seconds: 10));
    expect(first.skippedByDHash, isFalse);
    expect(first.dHash, isNotNull);
    expect(second.skippedByDHash, isTrue);
    expect(second.bytes, isEmpty);
    expect(second.dHash, first.dHash);
  });
}

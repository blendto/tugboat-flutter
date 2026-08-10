import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/screenshot_encode_isolate.dart';

void main() {
  test('persistent encode isolate returns jpeg bytes and content hash', () async {
    final worker = ScreenshotEncodeIsolate();
    addTearDown(worker.dispose);
    final rgba = Uint8List(4 * 8 * 8);
    for (var i = 0; i < rgba.length; i += 4) {
      rgba[i] = 255;
      rgba[i + 3] = 255;
    }
    final first = await worker
        .encode(rgba: rgba, width: 8, height: 8)
        .timeout(const Duration(seconds: 10));
    final second = await worker
        .encode(rgba: Uint8List.fromList(rgba), width: 8, height: 8)
        .timeout(const Duration(seconds: 10));
    expect(first.bytes, isNotEmpty);
    expect(first.contentHash, isNotEmpty);
    expect(second.contentHash, first.contentHash);
  });
}

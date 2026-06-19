import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'perceptual_hash.dart';

/// Encodes screenshot bytes off the UI isolate.
///
/// UI-bound work stays in [ScreenshotCapturer]: tree walks, [RenderRepaintBoundary.toImage],
/// and optional mask rasterization. Only transferable RGBA bytes cross into this worker path.

/// Raw RGBA screenshot bytes extracted on the UI isolate.
class RawScreenshotData {
  const RawScreenshotData({
    required this.rgba,
    required this.width,
    required this.height,
    required this.masked,
  });

  final Uint8List rgba;
  final int width;
  final int height;
  final bool masked;
}

/// PNG bytes and hashes produced off the UI isolate.
class EncodedScreenshot {
  const EncodedScreenshot({
    required this.bytes,
    required this.contentHash,
    required this.dHash,
    required this.encodeMicros,
  });

  final Uint8List bytes;
  final String contentHash;
  final String dHash;
  final int encodeMicros;
}

EncodedScreenshot _encodeScreenshotIsolate(RawScreenshotData input) {
  final sw = Stopwatch()..start();
  final dHash = computeDHashFromRgba(input.rgba, input.width, input.height);
  final image = img.Image.fromBytes(
    width: input.width,
    height: input.height,
    bytes: input.rgba.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  final png = Uint8List.fromList(img.encodePng(image));
  final hash = sha256.convert(png).toString();
  sw.stop();
  return EncodedScreenshot(
    bytes: png,
    contentHash: hash,
    dHash: dHash,
    encodeMicros: sw.elapsedMicroseconds,
  );
}

Future<EncodedScreenshot> encodeScreenshotOffThread(RawScreenshotData data) {
  return compute(_encodeScreenshotIsolate, data);
}

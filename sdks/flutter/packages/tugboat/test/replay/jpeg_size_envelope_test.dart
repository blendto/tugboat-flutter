import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/screenshot_encode.dart';

import '../../benchmark/jpeg_size_envelope.dart';

void main() {
  test('dart jpeg envelope stays inside documented solid and noisy bands', () {
    expect(screenshotJpegQuality, JpegSizeEnvelope.jpegQuality);

    final sizes = <(int, int)>[
      JpegSizeEnvelope.compactLogical,
      JpegSizeEnvelope.commonLogical,
      JpegSizeEnvelope.largeLogical,
    ];

    for (final logical in sizes) {
      final pixels = JpegSizeEnvelope.capturePixels(logical);
      final width = pixels.$1;
      final height = pixels.$2;
      final rgbaBytes = width * height * 4;

      final solid = encodeScreenshotRgba(
        ScreenshotEncodeInput(
          rgba: JpegSizeEnvelope.solidRgba(width, height),
          width: width,
          height: height,
          force: true,
        ),
      );
      final noisy = encodeScreenshotRgba(
        ScreenshotEncodeInput(
          rgba: JpegSizeEnvelope.noisyRgba(width, height),
          width: width,
          height: height,
          force: true,
        ),
      );

      expect(
        solid.bytes.length / rgbaBytes,
        lessThan(JpegSizeEnvelope.solidRatioMax),
      );
      expect(
        noisy.bytes.length / rgbaBytes,
        inInclusiveRange(
          JpegSizeEnvelope.noisyRatioMin,
          JpegSizeEnvelope.noisyRatioMax,
        ),
      );
    }

    const tiny = 8;
    final tinyRgba = tiny * tiny * 4;
    final tinyJpeg = encodeScreenshotRgba(
      ScreenshotEncodeInput(
        rgba: JpegSizeEnvelope.solidRgba(tiny, tiny),
        width: tiny,
        height: tiny,
        force: true,
      ),
    );
    expect(
      tinyJpeg.bytes.length / tinyRgba,
      greaterThan(JpegSizeEnvelope.tinyHeaderDominatedMinRatio),
    );
  });
}

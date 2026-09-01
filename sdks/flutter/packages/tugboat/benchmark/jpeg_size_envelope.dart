import 'dart:typed_data';

/// Regenerable JPEG size envelope for the current Dart `encodeJpg` path.
///
/// Dimensions are typical logical phone sizes multiplied by the default
/// `capturePixelRatio` of 0.75, then rounded. They are synthetic pixel
/// buffers, not measured device screenshots.
///
/// Noise uses a Park–Miller-style LCG (`seed = 1`,
/// `seed = (1103515245 * seed + 12345) & 0x7fffffff`) filling RGB from
/// successive low bytes. Re-run
/// `flutter test test/replay/jpeg_size_envelope_test.dart` after encoder
/// changes.
class JpegSizeEnvelope {
  static const jpegQuality = 80;
  static const capturePixelRatio = 0.75;

  static const compactLogical = (360, 800);
  static const commonLogical = (390, 844);
  static const largeLogical = (430, 932);

  /// Solid JPEG / RGBA. Headers plus a flat field.
  static const solidRatioMax = 0.02;

  /// Deterministic-noise JPEG / RGBA at quality 80.
  static const noisyRatioMin = 0.30;
  static const noisyRatioMax = 0.40;

  /// 8×8 fixtures are header-dominated; do not compare native JPEG to them.
  static const tinyHeaderDominatedMinRatio = 1.0;

  static (int, int) capturePixels((int, int) logical) => (
    (logical.$1 * capturePixelRatio).round(),
    (logical.$2 * capturePixelRatio).round(),
  );

  static Uint8List solidRgba(int width, int height) {
    final rgba = Uint8List(width * height * 4);
    for (var i = 0; i < rgba.length; i += 4) {
      rgba[i] = 32;
      rgba[i + 1] = 64;
      rgba[i + 2] = 128;
      rgba[i + 3] = 255;
    }
    return rgba;
  }

  static Uint8List noisyRgba(int width, int height) {
    final rgba = Uint8List(width * height * 4);
    var seed = 1;
    for (var i = 0; i < rgba.length; i += 4) {
      seed = (1103515245 * seed + 12345) & 0x7fffffff;
      rgba[i] = seed & 0xff;
      rgba[i + 1] = (seed >> 8) & 0xff;
      rgba[i + 2] = (seed >> 16) & 0xff;
      rgba[i + 3] = 255;
    }
    return rgba;
  }
}

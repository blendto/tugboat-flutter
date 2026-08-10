import 'dart:typed_data';

/// Computes a 64-bit difference hash from straight RGBA pixel bytes.
///
/// Downsamples to 9x8 grayscale and compares adjacent horizontal pixels.
String computeDHashFromRgba(Uint8List rgba, int width, int height) {
  if (width <= 0 || height <= 0 || rgba.isEmpty) return '';

  const hashWidth = 9;
  const hashHeight = 8;
  final pixels = List<int>.filled(hashWidth * hashHeight, 0);

  for (var y = 0; y < hashHeight; y++) {
    final srcY = ((y + 0.5) * height / hashHeight).floor().clamp(0, height - 1);
    for (var x = 0; x < hashWidth; x++) {
      final srcX = ((x + 0.5) * width / hashWidth).floor().clamp(0, width - 1);
      final offset = (srcY * width + srcX) * 4;
      if (offset + 2 >= rgba.length) continue;
      final r = rgba[offset];
      final g = rgba[offset + 1];
      final b = rgba[offset + 2];
      pixels[y * hashWidth + x] = ((r * 299 + g * 587 + b * 114) ~/ 1000);
    }
  }

  final bits = StringBuffer();
  for (var y = 0; y < hashHeight; y++) {
    for (var x = 0; x < hashWidth - 1; x++) {
      final left = pixels[y * hashWidth + x];
      final right = pixels[y * hashWidth + x + 1];
      bits.write(left < right ? '1' : '0');
    }
  }
  return bits.toString();
}

/// Hamming distance between two equal-length bit strings.
///
/// Returns a large sentinel when either input is empty or lengths differ so
/// callers can treat malformed hashes as non-matching.
int dHashHammingDistance(String a, String b) {
  if (a.isEmpty || b.isEmpty || a.length != b.length) {
    return 0x7fffffff;
  }
  var distance = 0;
  for (var i = 0; i < a.length; i++) {
    if (a.codeUnitAt(i) != b.codeUnitAt(i)) distance++;
  }
  return distance;
}

/// Maximum Hamming distance treated as visually unchanged for coalesce.
///
/// A couple of flipped bits typically cover single-pixel anti-alias shimmer
/// without swallowing meaningful UI changes.
const int dHashMatchDistance = 2;

/// Whether [candidate] is close enough to [previous] to skip JPEG encoding.
bool dHashVisuallyMatches(String? previous, String candidate) {
  if (previous == null || previous.isEmpty || candidate.isEmpty) return false;
  return dHashHammingDistance(previous, candidate) <= dHashMatchDistance;
}

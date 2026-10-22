import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/collector_retry_after.dart';

void main() {
  final vectorsFile = File(
    '${Directory.current.path}/../../../../conformance/retry_after_vectors.json',
  );

  test('shared conformance vectors', () {
    expect(vectorsFile.existsSync(), isTrue);
    final doc =
        jsonDecode(vectorsFile.readAsStringSync()) as Map<String, dynamic>;
    final capMs = doc['capMs'] as int;
    final wallUs = doc['nowWallUs'] as int;
    final now = DateTime.fromMicrosecondsSinceEpoch(wallUs, isUtc: true);
    final vectors = doc['vectors'] as List<dynamic>;
    for (final entry in vectors) {
      final map = entry as Map<String, dynamic>;
      final raw = map['raw'] as String;
      final expected = map['expectedMs'];
      final parsed = parseCollectorRetryAfterDelayMs(raw, now, capMs: capMs);
      if (expected == null) {
        expect(parsed, isNull, reason: raw);
      } else {
        expect(parsed, expected, reason: raw);
      }
    }
  });
}

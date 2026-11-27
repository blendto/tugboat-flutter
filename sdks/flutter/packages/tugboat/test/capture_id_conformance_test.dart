// Shared session/event id vectors (conformance/capture_id_vectors.json) that
// the C++ session engine also passes: 16 random bytes become
// `<prefix>-<UUIDv4>`, and every minted id matches the shared pattern.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/uuid.dart';

import 'helpers/conformance_fixture.dart';

/// A [Random] that returns the given bytes from `nextInt(256)`.
class _BytesRandom implements Random {
  _BytesRandom(this._bytes);

  final List<int> _bytes;
  var _index = 0;

  @override
  int nextInt(int max) {
    expect(max, 256);
    return _bytes[_index++];
  }

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  double nextDouble() => throw UnimplementedError();
}

List<int> _hexBytes(String hex) => [
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

void main() {
  final root = findConformanceRoot();
  final doc =
      jsonDecode(
            File(
              '${root.path}/$conformanceCaptureIdVectorsFile',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final pattern = RegExp(doc['idPattern']! as String);
  final vectors = (doc['vectors']! as List).cast<Map<String, Object?>>();

  test('shared vectors exist', () {
    expect(vectors.length, greaterThanOrEqualTo(8));
  });

  for (final vector in vectors) {
    test('capture id vector ${vector['name']}', () {
      final id = '${vector['prefix']}-'
          '${generateTugboatUuidV4(_BytesRandom(_hexBytes(vector['bytesHex']! as String)))}';
      expect(id, vector['expected']);
      expect(pattern.hasMatch(id), isTrue);
    });
  }

  test('minted ids match the shared pattern and do not repeat', () {
    final seen = <String>{};
    for (var i = 0; i < 500; i++) {
      for (final prefix in const ['session', 'event']) {
        final id = generateTugboatCaptureId(prefix);
        expect(pattern.hasMatch(id), isTrue, reason: id);
        expect(seen.add(id), isTrue, reason: 'duplicate $id');
      }
    }
  });
}

// Golden conformance fixtures shared with the future C++ session engine.
//
// Every fixture under `<repo>/conformance/` is evaluated against the current
// Dart implementation and compared with its committed `expected` value. The
// fixtures are reviewed artifacts: this test only reads them. To add or
// change one, edit the JSON by hand, run this test, review the printed
// actual output, and paste it into `expected` (see conformance/README.md).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/anchors.dart';
import 'package:tugboat/src/markers.dart';
import 'package:tugboat/src/models.dart';

import 'helpers/conformance_fixture.dart';

void main() {
  final root = findConformanceRoot();
  final files = listFixtureFiles(root);

  test('conformance/ holds fixtures for every kind', () {
    final kinds = {for (final file in files) loadFixture(root, file).kind};
    expect(kinds, ConformanceKind.values.toSet());
  });

  group('conformance fixture', () {
    for (final file in files) {
      final relativePath = fixtureRelativePath(root, file);
      test(relativePath, () => _expectFixture(loadFixture(root, file)));
    }
  });

  group('identity-parts mirror matches the resolver', () {
    testWidgets('fingerprint is the hash of routeKey and canonical path', (
      tester,
    ) async {
      final anchor = await _resolveAnchor(tester, tagId: null);

      expect(anchor.fingerprint, isNotEmpty);
      expect(
        anchor.fingerprint,
        conformanceIdentityFingerprint([
          MapEntry('routeKey', anchor.fingerprintParts['routeKey']!),
          MapEntry('path', anchor.canonicalPath!),
        ]),
      );
      expect(anchor.tagFingerprint, isNull);
    });

    testWidgets('tagFingerprint is the hash of routeKey and tag', (
      tester,
    ) async {
      final anchor = await _resolveAnchor(tester, tagId: 'pay-button');

      expect(anchor.fingerprintParts['tag'], 'pay-button');
      expect(
        anchor.tagFingerprint,
        conformanceIdentityFingerprint([
          const MapEntry('routeKey', '/checkout'),
          const MapEntry('tag', 'pay-button'),
        ]),
      );
    });
  });
}

void _expectFixture(ConformanceFixture fixture) {
  final name = fixture.relativePath.split('/').last;
  expect(name, '${fixture.name}.json', reason: 'name must match file name');
  expect(
    fixture.relativePath,
    startsWith('${fixture.kind.directory}/'),
    reason: 'kind ${fixture.kind.wireName} lives in ${fixture.kind.directory}',
  );
  final sdkContract = {
    'sessionSchemaVersion': tugboatSessionSchemaVersion,
    'fingerprintSchemaVersion': tugboatFingerprintSchemaVersion,
  };
  expect(
    fixture.contract,
    sdkContract,
    reason: 'fixture is pinned to other contract versions; review and re-pin',
  );

  final actual = evaluateFixture(fixture);
  final mismatches = diffJson(fixture.expected, actual, r'$.expected');
  if (mismatches.isEmpty) return;
  fail(
    '${fixture.relativePath} does not match the Dart implementation:\n'
    '  ${mismatches.join('\n  ')}\n'
    'Actual "expected" value (review before pasting):\n'
    '${encodeFixtureJson(actual)}',
  );
}

Future<TugboatTargetAnchor> _resolveAnchor(
  WidgetTester tester, {
  required String? tagId,
}) async {
  final rootKey = GlobalKey();
  final Widget button = FilledButton(
    onPressed: () {},
    child: const Text('Pay'),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: RepaintBoundary(
        key: rootKey,
        child: Scaffold(
          body: Center(
            child: tagId == null ? button : TugboatTag(tagId, child: button),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  final center = tester.getCenter(find.byType(FilledButton));
  return AnchorResolver(rootKey: rootKey).targetAt(center, route: '/checkout')!;
}

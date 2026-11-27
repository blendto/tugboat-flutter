// Golden conformance fixtures shared with the C++ session engine.
//
// Every fixture under `<repo>/conformance/` is evaluated against the current
// Dart implementation and compared with its committed `expected` value. The
// fixtures are reviewed artifacts: this test only reads them. To add or
// change one, edit the JSON by hand, run this test, review the printed
// actual output, and paste it into `expected` (see conformance/README.md).
// `engine.scenario` fixtures run step by step on a real controller
// (helpers/engine_scenario.dart); `engineOnly` scenarios and scenarios
// whose `runners` exclude `dart` are skipped.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/anchors.dart';
import 'package:tugboat/src/markers.dart';
import 'package:tugboat/src/models.dart';

import 'helpers/conformance_fixture.dart';
import 'helpers/delivery_rules_fixture.dart';
import 'helpers/engine_scenario.dart';
import 'helpers/engine_scenario_replay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final root = findConformanceRoot();
  final files = listFixtureFiles(root);

  test('conformance/ holds fixtures for every kind', () {
    final kinds = {for (final file in files) loadFixture(root, file).kind};
    expect(kinds, ConformanceKind.values.toSet());
  });

  group('conformance fixture', () {
    for (final file in files) {
      final fixture = loadFixture(root, file);
      test(
        fixture.relativePath,
        () => fixture.kind == ConformanceKind.deliveryRules
            ? _expectDeliveryRules(fixture, root)
            : _expectFixture(fixture),
        skip: _skipReason(fixture),
      );
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

/// The fingerprint schema the fixtures pin: the session engine's. Dart's own
/// is [tugboatFingerprintSchemaVersion].
const _engineFingerprintSchemaVersion = 6;

/// Kinds Dart stopped matching when Flutter 0.11.0–0.12.4 shipped on `main`
/// ahead of the engine: fingerprint schema 7 on collector records, UUID
/// session and event IDs, `appInfo.installationId`, and the reworked
/// collector sink (no `Retry-After` in Dart). The engine still runs them; the
/// Dart runner resumes once the engine catches up (BLE-618, BLE-621, BLE-622).
const _dartAheadOfEngine = {
  ConformanceKind.collectorEvent,
  ConformanceKind.sessionLifecycle,
  ConformanceKind.engineScenario,
};

String? _skipReason(ConformanceFixture fixture) {
  if (_dartAheadOfEngine.contains(fixture.kind)) {
    return 'Dart is ahead of the engine for ${fixture.kind.wireName} '
        '(tugboat 0.11.0-0.12.4); re-enable after the native catch-up';
  }
  if (fixture.deliveryParity) return null;
  if (fixture.engineOnly.isNotEmpty) {
    return 'engineOnly ${fixture.engineOnly.join(', ')}: Dart keeps its '
        'shipped behaviour';
  }
  if (!fixture.runsOnDart) return 'runners: C++ only';
  return null;
}

/// `delivery.rules` run against the real collector sink: the rules Dart's
/// `CollectorHttpSink` and the engine's delivery share.
Future<void> _expectDeliveryRules(
  ConformanceFixture fixture,
  Directory root,
) async {
  final name = fixture.relativePath.split('/').last;
  expect(name, '${fixture.name}.json', reason: 'name must match file name');
  expect(
    fixture.relativePath,
    startsWith('${fixture.kind.directory}/'),
    reason: 'kind ${fixture.kind.wireName} lives in ${fixture.kind.directory}',
  );
  final mismatches = await runDeliveryRulesOnDart(fixture, root);
  if (mismatches.isEmpty) return;
  fail(
    '${fixture.relativePath} does not match the Dart collector sink:\n'
    '  ${mismatches.join('\n  ')}',
  );
}

void _expectFixture(ConformanceFixture fixture) {
  final name = fixture.relativePath.split('/').last;
  expect(name, '${fixture.name}.json', reason: 'name must match file name');
  expect(
    fixture.relativePath,
    startsWith('${fixture.kind.directory}/'),
    reason: 'kind ${fixture.kind.wireName} lives in ${fixture.kind.directory}',
  );
  // The fixtures pin the session engine's contract. Flutter 0.11.0 moved to
  // fingerprint schema 7; the engine and the fixtures are still on 6 until the
  // native catch-up re-pins them (BLE-621).
  final sdkContract = {
    'sessionSchemaVersion': tugboatSessionSchemaVersion,
    'fingerprintSchemaVersion': _engineFingerprintSchemaVersion,
  };
  expect(
    fixture.contract,
    sdkContract,
    reason: 'fixture is pinned to other contract versions; review and re-pin',
  );

  if (fixture.kind == ConformanceKind.engineScenario) {
    final mismatches = fixture.deliveryParity
        ? replayDeliveryOnDart(fixture)
        : runEngineScenarioOnDart(fixture);
    if (mismatches.isEmpty) return;
    fail(
      '${fixture.relativePath} does not match the Dart '
      '${fixture.deliveryParity ? 'collector sink' : 'controller'}:\n'
      '  ${mismatches.join('\n  ')}',
    );
  }
  final actual = evaluateFixture(fixture);
  final mismatches = diffJson(fixture.expected, actual, r'$.expected');
  if (mismatches.isEmpty) {
    _expectEvidenceKeyOrder(fixture, actual);
    return;
  }
  fail(
    '${fixture.relativePath} does not match the Dart implementation:\n'
    '  ${mismatches.join('\n  ')}\n'
    'Actual "expected" value (review before pasting):\n'
    '${encodeFixtureJson(actual)}',
  );
}

/// Evidence data must be byte-identical to Dart's, so object key order is
/// compared too (both sides are insertion-ordered maps).
void _expectEvidenceKeyOrder(
  ConformanceFixture fixture,
  Map<String, Object?> actual,
) {
  if (fixture.kind != ConformanceKind.externalEvent &&
      fixture.kind != ConformanceKind.networkCall) {
    return;
  }
  expect(
    jsonEncode(actual),
    jsonEncode(fixture.expected),
    reason: '${fixture.relativePath}: key order differs from Dart',
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

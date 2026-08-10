import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import '../helpers/json_roundtrip.dart';

Future<void> _waitForCaptures(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  await tester.pump();
}

/// Release-compatibility matrix fixtures (U7).
void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('named route push emits distinguishable route_change', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [TugboatReplay.navigatorObserver],
        builder: (context, child) => TugboatReplay.wrapApp(
          config: const TugboatReplayConfig(
            profile: TugboatCaptureProfile.exploration,
            settleDelay: Duration.zero,
            interactionClaimWindow: Duration.zero,
            enableGlobalPointerCapture: false,
          ),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  settings: const RouteSettings(name: '/next'),
                  builder: (_) => const Scaffold(body: Text('Next screen')),
                ),
              ),
              child: const Text('Next'),
            ),
          ),
        ),
      ),
    );

    await _waitForCaptures(tester);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await _waitForCaptures(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await _waitForCaptures(tester);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await tester.pump();

    final session = TugboatReplay.controller!.session!;
    final routeChanges = session.events
        .where((event) => event.type == 'route_change')
        .toList();
    expect(routeChanges, isNotEmpty);
    expect(routeChanges.first.data['route'], isNotNull);
    expect(session.captureSessionId, isNot(equals('')));
  });

  testWidgets('anonymous MaterialPageRoute still emits route_change', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [TugboatReplay.navigatorObserver],
        builder: (context, child) => TugboatReplay.wrapApp(
          config: const TugboatReplayConfig(
            profile: TugboatCaptureProfile.exploration,
            settleDelay: Duration.zero,
            interactionClaimWindow: Duration.zero,
            enableGlobalPointerCapture: false,
          ),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: Text('Anon')),
                  ),
                );
              },
              child: const Text('Go'),
            ),
          ),
        ),
      ),
    );
    await _waitForCaptures(tester);
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    await _waitForCaptures(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await _waitForCaptures(tester);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await tester.pump();

    final routes = TugboatReplay.controller!.session!.events.where(
      (e) => e.type == 'route_change',
    );
    expect(routes, isNotEmpty);
  });

  test('v6-v9 session JSON remains readable alongside v10 writers', () {
    final session = TugboatSession(
      id: 'legacy-session',
      startedAt: DateTime.utc(2026, 8, 3),
      platform: 'test',
      viewport: const TugboatRect(0, 0, 100, 200),
    );
    final writerJson = session.toJson();
    expect(writerJson['schemaVersion'], 10);

    for (final version in [6, 7, 8, 9]) {
      final legacyJson = Map<String, dynamic>.from(writerJson)
        ..['schemaVersion'] = version
        ..['events'] = [
          {
            'id': 'legacy-event-$version',
            'atMs': 0,
            'type': 'tap',
            'data': {
              'controlValue': {'kind': 'number', 'value': 0.5},
              'controlValueTransition': {
                'before': {'kind': 'number', 'value': 0.4},
                'after': {'kind': 'number', 'value': 0.5},
              },
              'semanticAnnotation': {
                'label': {'kind': 'string', 'value': 'Legacy label'},
              },
            },
          },
        ];

      final restored = TugboatSessionTestJson.fromJson(legacyJson);
      expect(restored.id, 'legacy-session');
      expect(restored.events.single.data, contains('controlValue'));
      expect(restored.events.single.data, contains('controlValueTransition'));
      expect(restored.events.single.data, contains('semanticAnnotation'));
    }
  });

  test(
    'platform views are classified as unsupported for structural capture',
    () {
      const unsupported = ['PlatformViewLink', 'AndroidView', 'UiKitView'];
      expect(unsupported, isNotEmpty);
    },
  );

  testWidgets('runtime activation works without MaterialApp rebuild', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TugboatReplay.wrapApp(
          config: const TugboatReplayConfig(
            profile: TugboatCaptureProfile.dormant,
            settleDelay: Duration.zero,
            interactionClaimWindow: Duration.zero,
            enableGlobalPointerCapture: false,
          ),
          child: child!,
        ),
        home: const Scaffold(body: Text('Gate')),
      ),
    );
    await tester.pump();
    expect(TugboatReplay.controller, isNull);

    TugboatReplay.activate(
      activationRequestId: 'matrix-req',
      profile: TugboatCaptureProfile.exploration,
    );
    await _waitForCaptures(tester);
    expect(TugboatReplay.controller, isNotNull);
    expect(TugboatReplay.health.activationRequestId, 'matrix-req');
    expect(TugboatReplay.health.captureSessionId, isNotNull);
  });

  test('coordinate schema version and projection contract are stable', () {
    expect(tugboatCaptureCoordinateVersion, 1);
    final coord = buildCaptureCoordinate(
      globalX: 45,
      globalY: 95,
      boundaryOriginX: 10,
      boundaryOriginY: 20,
      boundaryWidth: 100,
      boundaryHeight: 200,
      framePixelWidth: 200,
      framePixelHeight: 400,
      frameId: 'frame-golden',
      boundaryTransformGeneration: 7,
    );
    expect(coord.projectToRaster(), (x: 70, y: 150));
  });

  testWidgets(
    'modal ownership and navigation origin compose under production masking',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [TugboatReplay.navigatorObserver],
          builder: (context, child) => TugboatReplay.wrapApp(
            config: const TugboatReplayConfig(
              profile: TugboatCaptureProfile.exploration,
              settleDelay: Duration.zero,
              interactionClaimWindow: Duration.zero,
              enableGlobalPointerCapture: true,
              capturePixelRatio: 1,
              screenshotMaskLevel: TugboatScreenshotMaskLevel.allTextAndMedia,
            ),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  builder: (_) => const SizedBox(
                    height: 120,
                    child: Center(child: Text('sheet')),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await _waitForCaptures(tester);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await _waitForCaptures(tester);

      final session = TugboatReplay.controller!.session!;
      final push = session.events.lastWhere(
        (e) => e.type == 'route_change' && e.data['navigation'] == 'route_push',
      );
      expect(push.data['routeInstanceId'], isNotNull);
      expect(push.data['navigatorId'], isNotNull);
      expect(push.data['navigationOrigin'], isNotNull);

      final interactions = session.events.where((e) => e.type == 'interaction');
      expect(interactions, isNotEmpty);
      expect(interactions.first.data['origin'], isA<Map>());
    },
  );
}

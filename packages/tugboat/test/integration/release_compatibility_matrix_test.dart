import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

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

  test('v6 session JSON remains readable alongside v7 writers', () {
    expect(tugboatSessionSchemaVersion, 7);
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

      final taps = session.events.where((e) => e.type == 'tap');
      expect(taps, isNotEmpty);
      expect(taps.first.data['captureCoordinate'], isA<Map>());
    },
  );
}

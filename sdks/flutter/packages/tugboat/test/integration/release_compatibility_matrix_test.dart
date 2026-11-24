import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import '../helpers/widget_capture_wait.dart';

/// Release-compatibility matrix fixtures (U7).
void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('anonymous MaterialPageRoute still emits route_change', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [TugboatReplay.navigatorObserver],
        builder: (context, child) => TugboatReplay.wrapApp(
          config: const TugboatReplayConfig(
            enabled: true,
            emitSceneInventory: true,
            emitViewportSemanticMap: true,
            emitCaptureDiagnostics: true,
            acceptActionContext: true,
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
    await waitForTugboatCaptureWork(tester);
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    await waitForTugboatCaptureWork(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await waitForTugboatCaptureWork(tester);
    await settleTugboatCaptureWork(tester, maxWait: const Duration(seconds: 1));

    final routes = TugboatReplay.controller!.session!.events.where(
      (e) => e.type == 'route_change',
    );
    expect(routes, isNotEmpty);
  });

  testWidgets('runtime activation works without MaterialApp rebuild', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TugboatReplay.wrapApp(
          config: const TugboatReplayConfig(
            enabled: false,
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

    TugboatReplay.activate(activationRequestId: 'matrix-req');
    await waitForTugboatCaptureWork(tester);
    expect(TugboatReplay.controller, isNotNull);
    expect(TugboatReplay.health.activationRequestId, 'matrix-req');
    expect(TugboatReplay.health.captureSessionId, isNotNull);
  });

  testWidgets(
    'modal ownership and navigation origin compose under production masking',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [TugboatReplay.navigatorObserver],
          builder: (context, child) => TugboatReplay.wrapApp(
            config: const TugboatReplayConfig(
              enabled: true,
              emitSceneInventory: true,
              emitViewportSemanticMap: true,
              emitCaptureDiagnostics: true,
              acceptActionContext: true,
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
      await waitForTugboatCaptureWork(tester);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await waitForTugboatCaptureWork(tester);

      final session = TugboatReplay.controller!.session!;
      final push = session.events.lastWhere(
        (e) => e.type == 'route_change' && e.data['navigation'] == 'route_push',
      );
      expect(push.data['routeInstanceId'], isNotNull);
      expect(push.data['navigatorId'], isNotNull);
      expect(push.data['navigationOrigin'], isNotNull);

      final interactions = session.events.where((e) => e.type == 'interaction');
      expect(interactions, isNotEmpty);
      expect(interactions.first.data.containsKey('origin'), isFalse);
      expect(interactions.first.data['interactionSchema'], 2);
    },
  );
}

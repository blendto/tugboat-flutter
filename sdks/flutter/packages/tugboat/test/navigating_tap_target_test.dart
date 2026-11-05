import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import 'helpers/widget_capture_wait.dart';

// The production defaults that matter here: pointers are read through the
// global pointer route (after the app's own gesture recognizers), and no scene
// inventory is emitted.
const _config = TugboatReplayConfig(
  enabled: true,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  capturePixelRatio: 1.0,
);

Future<TugboatEvent?> _tapInteraction(WidgetTester tester) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    final events = TugboatReplay.controller?.session?.events ?? const [];
    for (final event in events) {
      if (event.type == 'interaction' && event.data['gesture'] == 'tap') {
        return event;
      }
    }
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }
  return null;
}

Widget _app({required void Function(BuildContext) onTap}) {
  return MaterialApp(
    navigatorObservers: [TugboatReplay.navigatorObserver],
    builder: (context, child) =>
        TugboatReplay.wrapApp(config: _config, child: child!),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => onTap(context),
            child: const Text('Continue'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets(
    'a tap whose handler opens another screen keeps its target (BLE-459)',
    (tester) async {
      await tester.pumpWidget(
        _app(
          onTap: (context) => Navigator.of(context).push(
            MaterialPageRoute<void>(
              settings: const RouteSettings(name: '/next'),
              builder: (_) => const Scaffold(body: Text('Next screen')),
            ),
          ),
        ),
      );
      await waitForTugboatCaptureWork(tester);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      final tap = await _tapInteraction(tester);

      expect(tap, isNotNull);
      final anchor = tap!.targetAnchor;
      expect(anchor?.fingerprint, isNotNull);
      expect(anchor?.role, isNotNull);
      expect(anchor?.canonicalPath, contains('FilledButton#0'));
      await waitForTugboatCaptureWork(tester);
    },
  );

  testWidgets(
    'a tap that stays on the screen resolves the same target as before',
    (tester) async {
      await tester.pumpWidget(_app(onTap: (_) {}));
      await waitForTugboatCaptureWork(tester);

      await tester.tap(find.text('Continue'));
      await tester.pump();
      final tap = await _tapInteraction(tester);

      expect(tap, isNotNull);
      final anchor = tap!.targetAnchor;
      expect(anchor?.fingerprint, isNotNull);
      expect(anchor?.role, isNotNull);
      expect(anchor?.canonicalPath, contains('FilledButton#0'));
      await waitForTugboatCaptureWork(tester);
    },
  );
}

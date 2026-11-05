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

List<TugboatEvent> _taps() => [
  for (final event
      in TugboatReplay.controller?.session?.events ?? const <TugboatEvent>[])
    if (event.type == 'interaction' && event.data['gesture'] == 'tap') event,
];

Future<List<TugboatEvent>> _waitForTaps(WidgetTester tester, int count) async {
  for (var attempt = 0; attempt < 20 && _taps().length < count; attempt++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }
  return _taps();
}

Widget _app({
  required void Function(BuildContext) onTap,
  Map<String, WidgetBuilder> routes = const {},
}) {
  return MaterialApp(
    routes: routes,
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
      // The same button is tapped twice: first it stays on the screen, then it
      // opens another one. Both taps must record the same control, with the
      // fingerprint of the screen the button is on.
      var navigate = false;
      await tester.pumpWidget(
        _app(
          onTap: (context) {
            if (!navigate) return;
            Navigator.of(context).pushNamed('/next');
          },
          routes: {'/next': (_) => const Scaffold(body: Text('Next screen'))},
        ),
      );
      await waitForTugboatCaptureWork(tester);

      await tester.tap(find.text('Continue'));
      await tester.pump();
      await _waitForTaps(tester, 1);
      await waitForTugboatCaptureWork(tester);

      navigate = true;
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      final taps = await _waitForTaps(tester, 2);

      expect(taps, hasLength(2));
      final stayed = taps[0].targetAnchor;
      final navigated = taps[1].targetAnchor;
      expect(stayed?.fingerprint, isNotNull);
      expect(navigated?.role, isNotNull);
      expect(navigated?.canonicalPath, contains('FilledButton#0'));
      expect(navigated?.fingerprint, stayed?.fingerprint);
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
      final taps = await _waitForTaps(tester, 1);

      expect(taps, hasLength(1));
      final anchor = taps.single.targetAnchor;
      expect(anchor?.fingerprint, isNotNull);
      expect(anchor?.role, isNotNull);
      expect(anchor?.canonicalPath, contains('FilledButton#0'));
      await waitForTugboatCaptureWork(tester);
    },
  );
}

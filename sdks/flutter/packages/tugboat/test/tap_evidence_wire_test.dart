import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import 'helpers/widget_capture_wait.dart';

// Production defaults: pointers are read through the global pointer route and
// no scene inventory is emitted.
const _production = TugboatReplayConfig(
  enabled: true,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  capturePixelRatio: 1.0,
);

// Exploration: scene inventory emission on, which resolves taps at pointer-down.
const _exploration = TugboatReplayConfig(
  enabled: true,
  emitSceneInventory: true,
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

Widget _button(String label, VoidCallback onPressed, {String? tag}) {
  final button = FilledButton(onPressed: onPressed, child: Text(label));
  return tag == null ? button : TugboatTag(tag, child: button);
}

Widget _app(
  TugboatReplayConfig config, {
  required VoidCallback Function(BuildContext) onPressed,
  String? tag,
}) {
  return MaterialApp(
    initialRoute: '/home',
    navigatorObservers: [TugboatReplay.navigatorObserver],
    builder: (context, child) =>
        TugboatReplay.wrapApp(config: config, child: child!),
    routes: {
      '/home': (context) => Scaffold(
        body: Center(child: _button('Continue', onPressed(context), tag: tag)),
      ),
      '/next': (context) => const Scaffold(body: Text('Next screen')),
    },
  );
}

Future<Map<String, Object?>> _singleTap(
  WidgetTester tester,
  TugboatReplayConfig config, {
  String? tag,
}) async {
  await tester.pumpWidget(_app(config, onPressed: (_) => () {}, tag: tag));
  await waitForTugboatCaptureWork(tester);
  await tester.tap(find.text('Continue'));
  await tester.pump();
  final taps = await _waitForTaps(tester, 1);
  expect(taps, hasLength(1));
  await waitForTugboatCaptureWork(tester);
  return taps.single.data;
}

void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('a production tap carries confidence, source and routeKey', (
    tester,
  ) async {
    final data = await _singleTap(tester, _production);

    expect(data['targetFingerprint'], isNotNull);
    expect(data['fingerprintConfidence'], isIn(['low', 'medium', 'high']));
    expect(data['fingerprintSource'], 'pointerUp');
    expect(data['routeKey'], '/home');
    // The raw route is unchanged for existing consumers.
    expect(data['route'], '/home');
  });

  testWidgets('a tagged control reports high confidence and source tag', (
    tester,
  ) async {
    final data = await _singleTap(tester, _production, tag: 'continue-cta');

    expect(data['fingerprintConfidence'], 'high');
    expect(data['fingerprintSource'], 'tag');
  });

  testWidgets('an untagged control is never reported as high', (tester) async {
    final data = await _singleTap(tester, _production);

    expect(data['fingerprintConfidence'], isNot('high'));
  });

  testWidgets('an exploration tap resolves at pointer-down with its routeKey', (
    tester,
  ) async {
    final data = await _singleTap(tester, _exploration);

    expect(data['targetFingerprint'], isNotNull);
    expect(data['fingerprintConfidence'], isNotNull);
    expect(data['fingerprintSource'], 'pointerDown');
    expect(data['routeKey'], '/home');
  });

  testWidgets(
    'production and exploration give the same (routeKey, fingerprint) for one tap',
    (tester) async {
      final production = await _singleTap(tester, _production);
      await tester.pumpWidget(const SizedBox());
      TugboatReplay.resetForTest();
      final exploration = await _singleTap(tester, _exploration);

      expect(exploration['routeKey'], production['routeKey']);
      expect(exploration['targetFingerprint'], production['targetFingerprint']);
    },
  );

  for (final config in [_production, _exploration]) {
    final mode = identical(config, _production) ? 'production' : 'exploration';
    testWidgets(
      'a $mode tap on a control outside the navigator that navigates keeps '
      'the origin routeKey and fingerprint',
      (tester) async {
        // The bar button lives outside the Navigator, so the Navigator's
        // pointer absorption does not hide it after the push: a hit test at
        // pointer-up still finds it, but the current route is already the
        // destination. The same button is tapped twice, first staying put.
        final navigatorKey = GlobalKey<NavigatorState>();
        var navigate = false;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigatorKey,
            initialRoute: '/home',
            navigatorObservers: [TugboatReplay.navigatorObserver],
            builder: (context, child) => TugboatReplay.wrapApp(
              config: config,
              child: Column(
                children: [
                  Expanded(child: child!),
                  Material(
                    child: FilledButton(
                      onPressed: () {
                        if (navigate) {
                          navigatorKey.currentState!.pushNamed('/next');
                        }
                      },
                      child: const Text('Bar'),
                    ),
                  ),
                ],
              ),
            ),
            routes: {
              '/home': (_) => const Scaffold(body: Text('Home')),
              '/next': (_) => const Scaffold(body: Text('Next screen')),
            },
          ),
        );
        await waitForTugboatCaptureWork(tester);

        await tester.tap(find.text('Bar'));
        await tester.pump();
        await _waitForTaps(tester, 1);
        await waitForTugboatCaptureWork(tester);

        navigate = true;
        await tester.tap(find.text('Bar'));
        await tester.pumpAndSettle();
        final taps = await _waitForTaps(tester, 2);
        await waitForTugboatCaptureWork(tester);

        expect(taps, hasLength(2));
        final stayed = taps[0].data;
        final navigated = taps[1].data;
        expect(stayed['routeKey'], '/home');
        expect(navigated['route'], '/home');
        expect(navigated['routeKey'], '/home');
        expect(navigated['targetFingerprint'], stayed['targetFingerprint']);
        expect(navigated['fingerprintConfidence'], isNotNull);
      },
    );
  }
}

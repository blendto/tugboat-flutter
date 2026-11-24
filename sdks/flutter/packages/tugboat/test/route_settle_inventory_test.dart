import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import 'helpers/widget_capture_wait.dart';

// The route capture fired on a timer of the route's transition duration from
// the Navigator callback. The transition runs on frames and can lag behind
// it, and the covered route only goes offstage in the frame after it ends,
// so the `route` inventory of a pushed page could still list the page below
// it: its spinner, and an unnamed route's `struct:` key computed over both
// pages, a key no tap on the page carries.

const _exploration = TugboatReplayConfig(
  enabled: true,
  emitSceneInventory: true,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  capturePixelRatio: 1.0,
);

List<Map<String, Object?>> _inventories() => [
  for (final event in TugboatReplay.controller!.session!.events)
    if (event.type == 'scene_inventory') event.data,
];

class _Home extends StatelessWidget {
  const _Home({required this.details});
  final Widget details;
  @override
  // No Scaffold: nothing on this page blocks what lies beneath it, so while
  // it is still in the tree it is part of the pushed route's inventory.
  Widget build(BuildContext context) => Column(
    children: [
      const CircularProgressIndicator(),
      FilledButton(
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => details)),
        child: const Text('Go'),
      ),
    ],
  );
}

/// A page with one control.
class _Single extends StatelessWidget {
  const _Single();
  @override
  Widget build(BuildContext context) => Scaffold(
    body: FilledButton(onPressed: () {}, child: const Text('Buy')),
  );
}

class _Details extends StatelessWidget {
  const _Details();
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        FilledButton(onPressed: () {}, child: const Text('Buy')),
        OutlinedButton(onPressed: () {}, child: const Text('Later')),
      ],
    ),
  );
}

void main() {
  tearDown(TugboatReplay.resetForTest);

  for (final (name, details) in [
    ('two controls', const _Details()),
    ('one control', const _Single()),
  ]) {
    for (final scaffold in [false, true]) {
      testWidgets('an unnamed pushed page with $name: its route inventory has '
          'the key and fingerprint of the first tap on it', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [TugboatReplay.navigatorObserver],
            builder: (context, child) =>
                TugboatReplay.wrapApp(config: _exploration, child: child!),
            home: scaffold
                ? Scaffold(body: _Home(details: details))
                : _Home(details: details),
          ),
        );
        await waitForTugboatCaptureWork(tester);
        final homeKey = _inventories().last['routeKey'];

        await tester.tap(find.text('Go'));
        await tester.pump(const Duration(seconds: 1));
        await waitForTugboatCaptureWork(tester);
        final route = _inventories().lastWhere((e) => e['trigger'] == 'route');
        expect(route['routeKey'], isNot(homeKey));

        await tester.tap(find.text('Buy'));
        await tester.pump(const Duration(milliseconds: 300));
        await waitForTugboatCaptureWork(tester);
        final tap = TugboatReplay.controller!.session!.events.lastWhere(
          (e) => e.type == 'interaction' && e.data['gesture'] == 'tap',
        );

        // One key for the page: its route inventory, the tap, and every
        // inventory taken on it since.
        expect(tap.data['routeKey'], route['routeKey']);
        final onPage = _inventories().skip(_inventories().indexOf(route));
        expect(onPage.map((e) => e['routeKey']).toSet(), {route['routeKey']});
        final fingerprints = [
          for (final entry in (route['elements']! as List).cast<Map>())
            entry['fingerprint'],
        ];
        expect(fingerprints, contains(tap.data['targetFingerprint']));
      });
    }
  }
}

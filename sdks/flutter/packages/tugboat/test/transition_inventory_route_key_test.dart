import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import 'helpers/widget_capture_wait.dart';

// A device run of a host app emitted `trigger: manual` inventories whose
// route key was the destination of a running transition while their elements
// were the departing route's: a system back from a chooser listed the
// chooser's controls under the page below it, and a focus change while a
// dialog faded in listed the paywall under the dialog's `struct:` key.

const _exploration = TugboatReplayConfig(
  enabled: true,
  emitSceneInventory: true,
  captureSystemInput: true,
  captureFocusChanges: true,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  capturePixelRatio: 1.0,
);

final _marquee = ScrollController();

class ListPage extends StatelessWidget {
  const ListPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        SizedBox(
          height: 60,
          child: ListView(
            controller: _marquee,
            scrollDirection: Axis.horizontal,
            children: [
              for (var i = 0; i < 20; i++)
                SizedBox(width: 100, child: Text('Badge $i')),
            ],
          ),
        ),

        FilledButton(
          onPressed: () => Navigator.of(context).pushNamed('/details'),
          child: const Text('Open details'),
        ),
        FilledButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const OfferDialog(),
          ),
          child: const Text('Open offer'),
        ),
      ],
    ),
  );
}

class DetailsPage extends StatelessWidget {
  const DetailsPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        FilledButton(onPressed: () {}, child: const Text('Details one')),
        FilledButton(onPressed: () {}, child: const Text('Details two')),
      ],
    ),
  );
}

class OfferDialog extends StatelessWidget {
  const OfferDialog({super.key});
  @override
  Widget build(BuildContext context) => AlertDialog(
    actions: [TextButton(onPressed: () {}, child: const Text('Take offer'))],
  );
}

Future<void> _mount(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [HeroController(), TugboatReplay.navigatorObserver],
      builder: (context, child) =>
          TugboatReplay.wrapApp(config: _exploration, child: child!),
      initialRoute: '/list',
      routes: {
        '/list': (_) => const ListPage(),
        '/details': (_) => const DetailsPage(),
      },
    ),
  );
  await waitForTugboatCaptureWork(tester);
}

List<Map<String, Object?>> _inventories() => [
  for (final event in TugboatReplay.controller!.session!.events)
    if (event.type == 'scene_inventory') event.data,
];

Iterable<String> _paths(Map<String, Object?> inventory) => [
  for (final element in inventory['elements']! as List)
    (element as Map)['canonicalPath']! as String,
];

void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('system back does not list the departing page under the '
      'destination key', (tester) async {
    await _mount(tester);
    await tester.tap(find.text('Open details'));
    await tester.pumpAndSettle();
    await waitForTugboatCaptureWork(tester);
    expect(find.text('Details one'), findsOneWidget);
    final before = _inventories().length;

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await waitForTugboatCaptureWork(tester);

    final after = _inventories().skip(before).toList();
    expect([
      for (final inventory in after) inventory['routeKey'],
    ], everyElement('/list'));
    for (final inventory in after) {
      expect(
        _paths(inventory).where((p) => p.contains('DetailsPage')),
        isEmpty,
        reason: 'trigger ${inventory['trigger']} listed the departing page',
      );
    }
  });

  testWidgets('a capture requested while a dialog opens does not list the '
      'page under the dialog key', (tester) async {
    await _mount(tester);
    final before = _inventories().length;

    // The dialog is pushed but not yet built; an input observation (a focus
    // change) lands before its transition ends.
    await tester.tap(find.text('Open offer'));
    await TugboatReplay.controller!
        .debugRequestCapture(trigger: TugboatFrameTrigger.manual)
        .resolution;
    await tester.pumpAndSettle();
    await waitForTugboatCaptureWork(tester);

    final dialogInventories = [
      for (final inventory in _inventories().skip(before))
        if (inventory['routeKey'] != '/list') inventory,
    ];
    expect(dialogInventories, isNotEmpty);
    for (final inventory in dialogInventories) {
      expect(
        _paths(inventory).where((p) => p.contains('ListPage')),
        isEmpty,
        reason: 'trigger ${inventory['trigger']} listed the page below',
      );
    }
  });

  testWidgets('a programmatic scroll on the page below a popping route does '
      'not list the popping route under the page key', (tester) async {
    await _mount(tester);
    await tester.tap(find.text('Open details'));
    await tester.pumpAndSettle();
    await waitForTugboatCaptureWork(tester);
    final before = _inventories().length;

    await tester.binding.handlePopRoute();
    // The page's marquee keeps moving while the details page slides out.
    for (var i = 1; i <= 6; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      _marquee.jumpTo(i * 30.0);
    }
    await tester.pumpAndSettle();
    await waitForTugboatCaptureWork(tester);

    for (final inventory in _inventories().skip(before)) {
      expect(inventory['routeKey'], '/list');
      expect(
        _paths(inventory).where((p) => p.contains('DetailsPage')),
        isEmpty,
        reason: 'trigger ${inventory['trigger']} listed the departing page',
      );
    }
  });
}

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import 'helpers/widget_capture_wait.dart';

const _exploration = TugboatReplayConfig(
  enabled: true,
  emitSceneInventory: true,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  capturePixelRatio: 1.0,
);

class _FirstSheet extends StatelessWidget {
  const _FirstSheet();
  @override
  Widget build(BuildContext context) => const _SheetBody('First action');
}

// Public classes: private widgets never reach the canonical path.
class AlphaSheet extends StatelessWidget {
  const AlphaSheet({super.key});
  @override
  Widget build(BuildContext context) => const _SheetBody('Alpha action');
}

class BetaSheet extends StatelessWidget {
  const BetaSheet({super.key});
  @override
  Widget build(BuildContext context) => const _SheetBody('Beta action');
}

class _PrivateButtonSheet extends StatelessWidget {
  const _PrivateButtonSheet();
  @override
  Widget build(BuildContext context) =>
      FilledButton(onPressed: () {}, child: const Text('Only'));
}

class _PrivateScrollSheet extends StatelessWidget {
  const _PrivateScrollSheet();
  @override
  Widget build(BuildContext context) =>
      PageView(children: const [Center(child: Text('Page'))]);
}

class ManySheet extends StatelessWidget {
  const ManySheet({super.key});
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final label in ['One', 'Two', 'Three'])
        ListTile(onTap: () {}, title: Text(label)),
    ],
  );
}

class ConfirmDialog extends StatelessWidget {
  const ConfirmDialog({super.key});
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Sure?'),
    actions: [TextButton(onPressed: () {}, child: const Text('Confirm'))],
  );
}

class _SheetBody extends StatelessWidget {
  const _SheetBody(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FilledButton(onPressed: () {}, child: Text(label)),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

class _CustomPopupRoute extends PopupRoute<void> {
  @override
  Color? get barrierColor => const Color(0x80000000);
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => 'custom';
  @override
  Duration get transitionDuration => Duration.zero;
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> a,
    Animation<double> b,
  ) => Center(
    child: FilledButton(
      onPressed: () => Navigator.of(context).pop(),
      child: const Text('Custom close'),
    ),
  );
}

typedef _Opener = void Function(BuildContext context);

Future<void> _mount(
  WidgetTester tester,
  Widget Function(BuildContext) home,
) async {
  await tester.pumpWidget(
    MaterialApp(
      initialRoute: '/home',
      navigatorObservers: [TugboatReplay.navigatorObserver],
      builder: (context, child) =>
          TugboatReplay.wrapApp(config: _exploration, child: child!),
      routes: {
        '/home': (context) => Scaffold(body: Center(child: home(context))),
        '/next': (context) => Scaffold(
          body: FilledButton(
            onPressed: () {},
            child: const Text('Next action'),
          ),
        ),
      },
    ),
  );
  await waitForTugboatCaptureWork(tester);
}

Widget _openButton(_Opener opener) => Builder(
  builder: (context) =>
      FilledButton(onPressed: () => opener(context), child: const Text('Open')),
);

List<Map<String, Object?>> _inventories() => [
  for (final event in TugboatReplay.controller!.session!.events)
    if (event.type == 'scene_inventory') event.data,
];

Map<String, Object?> _surface(Map<String, Object?> inventory) =>
    (inventory['surface']! as Map).cast<String, Object?>();

List<TugboatEvent> _taps() => [
  for (final event in TugboatReplay.controller!.session!.events)
    if (event.type == 'interaction' && event.data['gesture'] == 'tap') event,
];

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await waitForTugboatCaptureWork(tester);
}

/// Opens the surface with the 'Open' button and returns the newest inventory
/// whose route key is not the home page's.
Future<Map<String, Object?>> _openAndInventory(
  WidgetTester tester,
  _Opener opener,
) async {
  await _mount(tester, (_) => _openButton(opener));
  await tester.tap(find.text('Open'));
  await _settle(tester);
  return _inventories().lastWhere((i) => i['routeKey'] != '/home');
}

void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('two anonymous sheets get a route key per widgetClass', (
    tester,
  ) async {
    final alpha = await _openAndInventory(
      tester,
      (c) => showModalBottomSheet<bool>(
        context: c,
        builder: (_) => const AlphaSheet(),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    TugboatReplay.resetForTest();
    final beta = await _openAndInventory(
      tester,
      (c) => showModalBottomSheet<bool>(
        context: c,
        builder: (_) => const BetaSheet(),
      ),
    );

    expect(alpha['routeKey'], 'sheet:AlphaSheet');
    expect(beta['routeKey'], 'sheet:BetaSheet');
    expect(_surface(alpha), {'kind': 'sheet', 'widgetClass': 'AlphaSheet'});
    expect(_surface(beta), {'kind': 'sheet', 'widgetClass': 'BetaSheet'});
  });

  testWidgets('a sheet with no nameable app class omits widgetClass', (
    tester,
  ) async {
    // A private class never reaches the canonical path, and an inline builder
    // returns framework widgets: neither is guessed.
    final private = await _openAndInventory(
      tester,
      (c) => showModalBottomSheet<bool>(
        context: c,
        builder: (_) => const _FirstSheet(),
      ),
    );
    expect(_surface(private), {'kind': 'sheet'});

    await tester.pumpWidget(const SizedBox());
    TugboatReplay.resetForTest();
    final inline = await _openAndInventory(
      tester,
      (c) => showModalBottomSheet<bool>(
        context: c,
        builder: (_) => ListTile(onTap: () {}, title: const Text('Row')),
      ),
    );
    expect(_surface(inline), {'kind': 'sheet'});

    for (final builder in <Widget Function()>[
      () => const _PrivateButtonSheet(),
      () => const _PrivateScrollSheet(),
    ]) {
      await tester.pumpWidget(const SizedBox());
      TugboatReplay.resetForTest();
      final single = await _openAndInventory(
        tester,
        (c) =>
            showModalBottomSheet<bool>(context: c, builder: (_) => builder()),
      );
      expect(_surface(single), {'kind': 'sheet'});
    }
  });

  testWidgets('a drag handle and several controls do not hide the class', (
    tester,
  ) async {
    final inventory = await _openAndInventory(
      tester,
      (c) => showModalBottomSheet<bool>(
        context: c,
        showDragHandle: true,
        builder: (_) => const ManySheet(),
      ),
    );

    expect(_surface(inventory), {'kind': 'sheet', 'widgetClass': 'ManySheet'});
  });

  testWidgets('a draggable sheet builder is not named after the framework', (
    tester,
  ) async {
    final inventory = await _openAndInventory(
      tester,
      (c) => showModalBottomSheet<bool>(
        context: c,
        isScrollControlled: true,
        builder: (_) => DraggableScrollableSheet(
          expand: false,
          builder: (_, controller) => ListView(
            controller: controller,
            children: [ListTile(onTap: () {}, title: const Text('Row'))],
          ),
        ),
      ),
    );

    expect(_surface(inventory), {'kind': 'sheet'});
  });

  testWidgets('a sheet under a shell with a nested navigator keeps its kind', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [TugboatReplay.navigatorObserver],
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _exploration, child: child!),
        home: Scaffold(
          bottomNavigationBar: BottomNavigationBar(
            items: const [
              BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
              BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Find'),
            ],
          ),
          body: Navigator(
            observers: [TugboatReplay.createNavigatorObserver()],
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              settings: const RouteSettings(name: '/inner'),
              builder: (_) => Center(
                child: _openButton(
                  (c) => showModalBottomSheet<bool>(
                    context: c,
                    builder: (_) => const AlphaSheet(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await waitForTugboatCaptureWork(tester);
    await tester.tap(find.text('Open'));
    await _settle(tester);
    final sheet = _inventories().lastWhere((i) => i['routeKey'] != '/inner');
    // The shell's bottom bar is a second retained root, so the class is left
    // out rather than guessed; the kind does not depend on the tree.
    expect(_surface(sheet), {'kind': 'sheet'});
  });

  testWidgets('a dialog reports kind dialog and its widgetClass', (
    tester,
  ) async {
    final inventory = await _openAndInventory(
      tester,
      (c) =>
          showDialog<void>(context: c, builder: (_) => const ConfirmDialog()),
    );

    expect(inventory['routeKey'], 'dialog:ConfirmDialog');
    expect(_surface(inventory), {
      'kind': 'dialog',
      'widgetClass': 'ConfirmDialog',
    });
  });

  testWidgets('a Cupertino popup reports as a sheet', (tester) async {
    final inventory = await _openAndInventory(
      tester,
      (c) => showCupertinoModalPopup<void>(
        context: c,
        builder: (_) => const AlphaSheet(),
      ),
    );

    expect(_surface(inventory), {'kind': 'sheet', 'widgetClass': 'AlphaSheet'});
  });

  testWidgets('a named dialog keeps its kind under a stable route key', (
    tester,
  ) async {
    final inventory = await _openAndInventory(
      tester,
      (c) => showDialog<void>(
        context: c,
        routeSettings: const RouteSettings(name: '/confirm'),
        builder: (_) => const ConfirmDialog(),
      ),
    );

    expect(inventory['routeKey'], '/confirm');
    expect(_surface(inventory)['kind'], 'dialog');
  });

  testWidgets('a custom PopupRoute is a popup', (tester) async {
    final inventory = await _openAndInventory(
      tester,
      (c) => Navigator.of(c).push(_CustomPopupRoute()),
    );

    expect(_surface(inventory)['kind'], 'popup');
  });

  testWidgets('a popup menu and a dropdown are menus without a widgetClass', (
    tester,
  ) async {
    await _mount(
      tester,
      (_) => Column(
        children: [
          PopupMenuButton<int>(
            itemBuilder: (_) => const [
              PopupMenuItem(value: 1, child: Text('One')),
            ],
            child: const Text('Menu'),
          ),
          DropdownButton<int>(
            value: 1,
            items: const [DropdownMenuItem(value: 1, child: Text('Choice'))],
            onChanged: (_) {},
          ),
        ],
      ),
    );

    await tester.tap(find.text('Menu'));
    await _settle(tester);
    final menu = _inventories().lastWhere((i) => i['routeKey'] != '/home');
    expect(_surface(menu), {'kind': 'menu'});

    await tester.tapAt(const Offset(2, 2));
    await _settle(tester);
    final before = _inventories().length;
    await tester.tap(find.text('Choice'));
    await _settle(tester);
    final dropdown = _inventories()
        .skip(before)
        .lastWhere((i) => _surface(i)['kind'] == 'menu');
    expect(_surface(dropdown), {'kind': 'menu'});
  });

  testWidgets('pages report kind page, unnamed or named', (tester) async {
    final unnamed = await _openAndInventory(
      tester,
      (c) => Navigator.of(c).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: FilledButton(onPressed: () {}, child: const Text('Page')),
          ),
        ),
      ),
    );
    expect((unnamed['routeKey']! as String).startsWith('struct:'), isTrue);
    expect(_surface(unnamed), {'kind': 'page'});

    await tester.pumpWidget(const SizedBox());
    TugboatReplay.resetForTest();
    final named = await _openAndInventory(
      tester,
      (c) => Navigator.of(c).pushNamed('/next'),
    );
    expect(named['routeKey'], '/next');
    expect(_surface(named), {'kind': 'page'});
  });

  testWidgets('an exploration tap on a sheet control carries its surface', (
    tester,
  ) async {
    final inventory = await _openAndInventory(
      tester,
      (c) => showModalBottomSheet<bool>(
        context: c,
        builder: (_) => const AlphaSheet(),
      ),
    );
    final taps = _taps().length;

    await tester.tap(find.text('Alpha action'));
    await tester.pump();
    for (var i = 0; i < 20 && _taps().length == taps; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    await waitForTugboatCaptureWork(tester);

    final tap = _taps().last.data;
    expect(tap['routeKey'], inventory['routeKey']);
    expect(tap['surface'], _surface(inventory));
    expect(tap['surface'], {'kind': 'sheet', 'widgetClass': 'AlphaSheet'});
  });

  testWidgets('a tap on the page after a sheet closes reports page', (
    tester,
  ) async {
    await _mount(
      tester,
      (_) => _openButton(
        (c) => showModalBottomSheet<bool>(
          context: c,
          builder: (_) => const AlphaSheet(),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await _settle(tester);
    await tester.tap(find.text('Close'));
    await _settle(tester);
    await tester.tap(find.text('Open'));
    await tester.pump();
    await waitForTugboatCaptureWork(tester);

    final kinds = [
      for (final tap in _taps()) (tap.data['surface']! as Map)['kind'],
    ];
    expect(kinds, ['page', 'sheet', 'page']);
  });

  testWidgets('surface never enters the inventory hash or fingerprints', (
    tester,
  ) async {
    final inventory = await _openAndInventory(
      tester,
      (c) => showModalBottomSheet<bool>(
        context: c,
        builder: (_) => const AlphaSheet(),
      ),
    );
    final elements = (inventory['elements']! as List).cast<Map>();
    final fingerprints = [for (final e in elements) e['fingerprint']! as String]
      ..sort();

    expect(
      inventory['inventoryHash'],
      tugboatLabelHash(fingerprints.join('|')),
    );
    expect(elements.first['canonicalPath'], contains('AlphaSheet#0/'));
    expect(
      [for (final e in elements) e['canonicalPath']],
      everyElement(
        startsWith(
          'DisplayFeatureSubScreen/BottomSheet#0/RawGestureDetector#0/',
        ),
      ),
    );
  });
}

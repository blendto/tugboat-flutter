import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/anchors.dart';

/// Route keys of anonymous sheets and dialogs (#137). The schema 6 fingerprint
/// constants were observed on the schema 6 tree (a worktree at 4f1b72e) with
/// the same widgets and route strings. They must be aliases of the schema 7
/// entries.
const _alphaSheetV6 = '5b6aa5e67f93f5ff';
const _sheetRouteName = 'ModalBottomSheetRoute<bool>';

class KeyAlphaSheet extends StatelessWidget {
  const KeyAlphaSheet({super.key});
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      FilledButton(onPressed: () {}, child: const Text('Sheet action')),
    ],
  );
}

class KeyBetaSheet extends StatelessWidget {
  const KeyBetaSheet({super.key});
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      FilledButton(onPressed: () {}, child: const Text('Beta action')),
    ],
  );
}

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
}

Future<GlobalKey> _mountHome(
  WidgetTester tester,
  void Function(BuildContext) onHome,
) async {
  final rootKey = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => RepaintBoundary(key: rootKey, child: child!),
      home: Builder(
        builder: (context) {
          onHome(context);
          return const Text('Home');
        },
      ),
    ),
  );
  return rootKey;
}

TugboatSceneInventory _inventory(GlobalKey rootKey, String route) {
  final inventory = AnchorResolver(rootKey: rootKey).buildSceneInventory(
    route: route,
    keyboardOpen: false,
    modalOpen: true,
    surfaceKind: TugboatSurfaceKind.sheet,
    withBoundsEvidence: true,
  );
  expect(inventory, isNotNull);
  return inventory!;
}

void main() {
  testWidgets('a named sheet class gives its own route key and the alias', (
    tester,
  ) async {
    _bigView(tester);
    late BuildContext home;
    final rootKey = await _mountHome(tester, (c) => home = c);
    showModalBottomSheet<bool>(
      context: home,
      builder: (_) => const KeyAlphaSheet(),
    );
    await tester.pumpAndSettle();

    final inventory = _inventory(rootKey, _sheetRouteName);
    expect(inventory.routeKey, 'sheet:KeyAlphaSheet');
    expect(inventory.surface.widgetClass, 'KeyAlphaSheet');
    final target = AnchorResolver(rootKey: rootKey).targetAt(
      tester.getCenter(find.text('Sheet action')),
      route: _sheetRouteName,
    );
    expect(target?.fingerprint, isNotNull);
    expect(
      inventory.elements.any(
        (entry) => entry.fingerprint == target!.fingerprint,
      ),
      isTrue,
      reason: 'the tap resolves to the inventory entry of its route',
    );
    final carried = inventory.elements.any(
      (entry) => entry.aliases.contains(_alphaSheetV6),
    );
    expect(carried, isTrue, reason: 'schema 6 $_alphaSheetV6 is not carried');
  });

  testWidgets('a sheet with an inline builder keeps its runtime type key', (
    tester,
  ) async {
    _bigView(tester);
    late BuildContext home;
    final rootKey = await _mountHome(tester, (c) => home = c);
    showModalBottomSheet<bool>(
      context: home,
      builder: (_) => FilledButton(onPressed: () {}, child: const Text('X')),
    );
    await tester.pumpAndSettle();

    final inventory = _inventory(rootKey, _sheetRouteName);
    expect(inventory.routeKey, _sheetRouteName);
  });

  testWidgets('a host-named sheet keeps its name', (tester) async {
    _bigView(tester);
    late BuildContext home;
    final rootKey = await _mountHome(tester, (c) => home = c);
    showModalBottomSheet<bool>(
      context: home,
      routeSettings: const RouteSettings(name: '/pick'),
      builder: (_) => const KeyAlphaSheet(),
    );
    await tester.pumpAndSettle();

    expect(_inventory(rootKey, '/pick').routeKey, '/pick');
  });

  testWidgets('a stacked copy of the same sheet keeps its class key', (
    tester,
  ) async {
    _bigView(tester);
    late BuildContext home;
    final rootKey = await _mountHome(tester, (c) => home = c);
    showModalBottomSheet<bool>(
      context: home,
      builder: (_) => const KeyAlphaSheet(),
    );
    await tester.pumpAndSettle();
    final alone = _inventory(rootKey, _sheetRouteName);
    showModalBottomSheet<bool>(
      context: home,
      builder: (_) => const KeyAlphaSheet(),
    );
    await tester.pumpAndSettle();
    final stacked = _inventory(rootKey, _sheetRouteName);

    expect(alone.routeKey, 'sheet:KeyAlphaSheet');
    expect(stacked.routeKey, alone.routeKey);
  });
}

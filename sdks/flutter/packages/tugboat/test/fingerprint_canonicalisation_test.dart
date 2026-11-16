import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/anchors.dart';
import 'package:tugboat/tugboat.dart';

/// Canonicalisation (#139): overlay ordinals, transparent theme wrappers and
/// list positions. The schema 6 fingerprints below were observed on the
/// schema 6 tree (a worktree at 4f1b72e) with the same widgets. Each must
/// appear in the aliases of the matching schema 7 entry.
const _sheetAloneV6 = '0f65ad18a79de43f';
const _sheetStackedV6 = '7dc266f722e6247d';
const _listTilePlainV6 = '7671cd5855cba88b';
const _listTileWrappedV6 = '6e26279642687797';
const _switchWrappedV6 = '6ee57f564d629ae7';

const _sheetRoute = 'ModalBottomSheetRoute<bool>';

/// Two named sheet classes that share one component, [SharedRow].
class SharedRow extends StatelessWidget {
  const SharedRow({super.key});
  @override
  Widget build(BuildContext context) =>
      FilledButton(onPressed: () {}, child: const Text('Shared'));
}

class SharedAlphaSheet extends StatelessWidget {
  const SharedAlphaSheet({super.key});
  @override
  Widget build(BuildContext context) =>
      const Column(mainAxisSize: MainAxisSize.min, children: [SharedRow()]);
}

class SharedBetaSheet extends StatelessWidget {
  const SharedBetaSheet({super.key});
  @override
  Widget build(BuildContext context) =>
      const Column(mainAxisSize: MainAxisSize.min, children: [SharedRow()]);
}

Widget _sheetBody() => Column(
  mainAxisSize: MainAxisSize.min,
  children: [FilledButton(onPressed: () {}, child: const Text('Sheet action'))],
);

TugboatSceneInventory _inventory(
  GlobalKey rootKey,
  String route, {
  bool modal = false,
}) {
  final inventory = AnchorResolver(rootKey: rootKey).buildSceneInventory(
    route: route,
    keyboardOpen: false,
    modalOpen: modal,
    withBoundsEvidence: true,
  );
  expect(inventory, isNotNull);
  return inventory!;
}

Set<String> _interactiveFingerprints(TugboatSceneInventory inventory) => {
  for (final entry in inventory.elements)
    if (entry.tier == 'interactive') entry.fingerprint,
};

/// Expects an interactive entry to carry [legacy], as its primary or alias.
void _expectCarriesLegacy(TugboatSceneInventory inventory, String legacy) {
  final carried = inventory.elements.any(
    (entry) =>
        entry.tier == 'interactive' &&
        (entry.fingerprint == legacy || entry.aliases.contains(legacy)),
  );
  expect(carried, isTrue, reason: 'schema 6 $legacy is not carried');
}

void _setBigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
}

void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets(
    'a sheet opened on top of another has the fingerprints of the same control',
    (tester) async {
      _setBigView(tester);
      final rootKey = GlobalKey();
      late BuildContext homeContext;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              RepaintBoundary(key: rootKey, child: child!),
          home: Builder(
            builder: (context) {
              homeContext = context;
              return const Text('Home');
            },
          ),
        ),
      );
      showModalBottomSheet<bool>(
        context: homeContext,
        builder: (_) => _sheetBody(),
      );
      await tester.pumpAndSettle();
      final alone = _inventory(rootKey, _sheetRoute, modal: true);

      showModalBottomSheet<bool>(
        context: homeContext,
        builder: (_) => _sheetBody(),
      );
      await tester.pumpAndSettle();
      final stacked = _inventory(rootKey, _sheetRoute, modal: true);

      expect(
        _interactiveFingerprints(stacked),
        _interactiveFingerprints(alone),
      );
      expect(_interactiveFingerprints(alone), hasLength(1));
      _expectCarriesLegacy(alone, _sheetAloneV6);
      _expectCarriesLegacy(stacked, _sheetStackedV6);
    },
  );

  testWidgets(
    'two different named sheets with a shared component keep them apart',
    (tester) async {
      _setBigView(tester);
      final rootKey = GlobalKey();
      late BuildContext homeContext;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              RepaintBoundary(key: rootKey, child: child!),
          home: Builder(
            builder: (context) {
              homeContext = context;
              return const Text('Home');
            },
          ),
        ),
      );
      showModalBottomSheet<bool>(
        context: homeContext,
        builder: (_) => const SharedAlphaSheet(),
      );
      await tester.pumpAndSettle();
      final alpha = _inventory(rootKey, _sheetRoute, modal: true);
      Navigator.of(homeContext).pop();
      await tester.pumpAndSettle();

      showModalBottomSheet<bool>(
        context: homeContext,
        builder: (_) => const SharedBetaSheet(),
      );
      await tester.pumpAndSettle();
      final beta = _inventory(rootKey, _sheetRoute, modal: true);

      expect(
        _interactiveFingerprints(
          alpha,
        ).intersection(_interactiveFingerprints(beta)),
        isEmpty,
      );
      expect(
        alpha.elements.single.canonicalPath,
        contains('SharedAlphaSheet#0/'),
      );
      expect(
        beta.elements.single.canonicalPath,
        contains('SharedBetaSheet#0/'),
      );
    },
  );

  testWidgets(
    'a ListTileTheme wrapper does not change a ListTile fingerprint',
    (tester) async {
      _setBigView(tester);
      final rootKey = GlobalKey();
      Future<void> pumpTile(Widget tile) => tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: rootKey,
            child: Scaffold(body: Column(children: [tile])),
          ),
        ),
      );

      await pumpTile(ListTile(onTap: () {}, title: const Text('Row')));
      final plain = _inventory(rootKey, '/w');
      await pumpTile(
        ListTileTheme(
          data: const ListTileThemeData(dense: true),
          child: ListTile(onTap: () {}, title: const Text('Row')),
        ),
      );
      final wrapped = _inventory(rootKey, '/w');

      expect(_interactiveFingerprints(plain), {_listTilePlainV6});
      expect(
        _interactiveFingerprints(wrapped),
        _interactiveFingerprints(plain),
      );
      _expectCarriesLegacy(wrapped, _listTileWrappedV6);
    },
  );

  testWidgets('a SwitchTheme wrapper does not change a Switch fingerprint', (
    tester,
  ) async {
    _setBigView(tester);
    final rootKey = GlobalKey();
    Future<void> pumpSwitch(Widget control) => tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: Scaffold(body: Column(children: [control])),
        ),
      ),
    );

    await pumpSwitch(Switch(value: false, onChanged: (_) {}));
    final plain = _inventory(rootKey, '/w');
    await pumpSwitch(
      SwitchTheme(
        data: const SwitchThemeData(),
        child: Switch(value: false, onChanged: (_) {}),
      ),
    );
    final wrapped = _inventory(rootKey, '/w');

    expect(_interactiveFingerprints(wrapped), _interactiveFingerprints(plain));
    _expectCarriesLegacy(wrapped, _switchWrappedV6);
  });

  testWidgets('a control at a list position is flagged positional', (
    tester,
  ) async {
    _setBigView(tester);
    final rootKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: Scaffold(
            body: Column(
              children: [
                FilledButton(onPressed: () {}, child: const Text('Outside')),
                Expanded(
                  child: ListView(
                    children: [
                      ListTile(onTap: () {}, title: const Text('Inside')),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final entries = _inventory(rootKey, '/list').elements.where(
      (entry) => entry.tier == 'interactive' && entry.actions.contains('tap'),
    );
    final positional = entries.where((entry) => entry.positional).toList();
    final fixed = entries.where((entry) => !entry.positional).toList();
    expect(positional, hasLength(1));
    expect(positional.single.canonicalPath, contains('[item:0]'));
    expect(fixed, hasLength(1));
    expect(fixed.single.canonicalPath, isNot(contains('[item:')));
  });

  testWidgets(
    'two tabs with different content at index 0 are both flagged positional',
    (tester) async {
      _setBigView(tester);
      Future<TugboatSceneInventory> tabsWith(Widget first) async {
        final rootKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(
              key: rootKey,
              child: DefaultTabController(
                length: 2,
                child: Scaffold(
                  body: Column(
                    children: [
                      const TabBar(
                        tabs: [
                          Tab(text: 'A'),
                          Tab(text: 'B'),
                        ],
                      ),
                      Expanded(
                        child: TabBarView(
                          children: [
                            Center(child: first),
                            const Center(child: Text('Second')),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return _inventory(rootKey, '/tabs');
      }

      final filled = await tabsWith(
        FilledButton(onPressed: () {}, child: const Text('Alpha')),
      );
      final elevated = await tabsWith(
        ElevatedButton(onPressed: () {}, child: const Text('Beta')),
      );

      for (final inventory in [filled, elevated]) {
        final inTab = inventory.elements.where(
          (entry) => entry.canonicalPath.contains('TabBarView'),
        );
        expect(inTab, isNotEmpty);
        expect(inTab.every((entry) => entry.positional), isTrue);
      }
    },
  );
}

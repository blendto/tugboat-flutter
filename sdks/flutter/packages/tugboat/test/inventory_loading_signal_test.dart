import 'dart:convert';

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

const _secretLabel = 'Secret label 7531';

/// A grid whose type name carries the `Shimmer` fragment, as a skeleton
/// package would.
class ShimmerGrid extends StatelessWidget {
  const ShimmerGrid({super.key});

  @override
  Widget build(BuildContext context) => _TileGrid();
}

/// The same grid after the content has loaded: no placeholder fragment.
class LoadedGrid extends StatelessWidget {
  const LoadedGrid({super.key});

  @override
  Widget build(BuildContext context) => _TileGrid();
}

class _TileGrid extends StatelessWidget {
  @override
  Widget build(BuildContext context) => GridView.count(
    crossAxisCount: 2,
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    children: [
      for (var i = 0; i < 4; i++)
        GestureDetector(
          onTap: () {},
          child: const ColoredBox(color: Colors.grey),
        ),
    ],
  );
}

Future<void> _mount(WidgetTester tester, Widget body) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [TugboatReplay.navigatorObserver],
      builder: (context, child) => TugboatReplay.wrapApp(
        config: _exploration,
        child: child!,
      ),
      home: Scaffold(body: body),
    ),
  );
  await waitForTugboatCaptureWork(tester);
}

List<Map<String, Object?>> _inventories() => [
  for (final event in TugboatReplay.controller!.session!.events)
    if (event.type == 'scene_inventory') event.data,
];

Map<String, Object?> _last() => _inventories().last;

Map<String, Object?> _loading(Map<String, Object?> inventory) =>
    (inventory['loading']! as Map).cast();

List<Map<String, Object?>> _elements(Map<String, Object?> inventory) => [
  for (final e in inventory['elements']! as List) (e as Map).cast(),
];

List<Map<String, Object?>> _flagged(Map<String, Object?> inventory) =>
    _elements(inventory).where((e) => e['placeholder'] == true).toList();

void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('a shimmer grid reports placeholders and marks its tiles', (
    tester,
  ) async {
    await _mount(tester, const ShimmerGrid());

    final inventory = _last();
    final loading = _loading(inventory);
    expect(loading['placeholders'], greaterThan(0));
    expect(_flagged(inventory), hasLength(loading['placeholders'] as int));
  });

  testWidgets('the same grid after load reports no placeholders or flags', (
    tester,
  ) async {
    await _mount(tester, const LoadedGrid());

    final inventory = _last();
    final loading = _loading(inventory);
    expect(loading['placeholders'], 0);
    expect(loading['progressIndicators'], 0);
    expect(loading['busyControls'], 0);
    expect(_flagged(inventory), isEmpty);
    expect(_elements(inventory), isNotEmpty);
    for (final entry in _elements(inventory)) {
      expect(entry.containsKey('placeholder'), isFalse);
    }
  });

  testWidgets('a page with one CircularProgressIndicator reports one', (
    tester,
  ) async {
    await _mount(
      tester,
      const Column(
        children: [
          FilledButton(onPressed: _noop, child: Text('Go')),
          Expanded(child: Center(child: CircularProgressIndicator())),
        ],
      ),
    );

    expect(_loading(_last())['progressIndicators'], 1);
  });

  testWidgets('TugboatLoading marks the controls in its subtree', (
    tester,
  ) async {
    await _mount(
      tester,
      Column(
        children: [
          const FilledButton(onPressed: _noop, child: Text('Live')),
          TugboatLoading(
            child: FilledButton(onPressed: () {}, child: const Text('Custom')),
          ),
        ],
      ),
    );

    final inventory = _last();
    expect(_loading(inventory)['placeholders'], 1);
    expect(_flagged(inventory), hasLength(1));
  });

  testWidgets('wrapping a control in TugboatLoading changes no fingerprint', (
    tester,
  ) async {
    await _mount(
      tester,
      const Center(
        child: FilledButton(onPressed: _noop, child: Text('Plain')),
      ),
    );
    final plain = _last();

    // A second session in the same test needs a fresh controller.
    await tester.pumpWidget(const SizedBox());
    TugboatReplay.resetForTest();
    await _mount(
      tester,
      Center(
        child: TugboatLoading(
          child: FilledButton(onPressed: () {}, child: const Text('Plain')),
        ),
      ),
    );
    final wrapped = _last();

    expect(wrapped['inventoryHash'], plain['inventoryHash']);
    expect(wrapped['routeKey'], plain['routeKey']);
    expect(wrapped['surface'], plain['surface']);
    final plainEntries = _elements(plain);
    final wrappedEntries = _elements(wrapped);
    expect(wrappedEntries, hasLength(plainEntries.length));
    for (var i = 0; i < plainEntries.length; i++) {
      expect(
        wrappedEntries[i]['fingerprint'],
        plainEntries[i]['fingerprint'],
      );
      expect(
        wrappedEntries[i]['canonicalPath'],
        plainEntries[i]['canonicalPath'],
      );
    }
  });

  testWidgets('controls under an absorbing pointer count as busy', (
    tester,
  ) async {
    await _mount(
      tester,
      const Center(
        child: AbsorbPointer(
          child: FilledButton(onPressed: _noop, child: Text('Busy')),
        ),
      ),
    );

    expect(_loading(_last())['busyControls'], 1);
  });

  testWidgets('no label text is emitted by the loading signal', (tester) async {
    await _mount(
      tester,
      ListView(
        children: [
          const ShimmerGrid(),
          TugboatLoading(
            child: FilledButton(
              onPressed: _noop,
              child: const Text(_secretLabel),
            ),
          ),
        ],
      ),
    );

    final encoded = jsonEncode(_inventories());
    expect(encoded, contains('"loading"'));
    expect(encoded, isNot(contains(_secretLabel)));
  });
}

void _noop() {}

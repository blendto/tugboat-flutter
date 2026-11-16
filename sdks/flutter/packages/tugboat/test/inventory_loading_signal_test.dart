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

/// A scope whose type argument names a shimmer, as `Provider<...>` would.
class _Scope<T> extends StatelessWidget {
  const _Scope({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

class ShimmerController {}

/// An inherited scope named like a skeleton: it carries state, draws nothing.
class SkeletonTheme extends InheritedWidget {
  const SkeletonTheme({required super.child, super.key});

  @override
  bool updateShouldNotify(SkeletonTheme oldWidget) => false;
}

/// A skeleton package's widget: its type name carries the `Skeleton` fragment
/// and it stays mounted whether or not it is loading.
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// A dialog: an app widget class `surface.widgetClass` can name.
class ConfirmDialog extends StatelessWidget {
  const ConfirmDialog({super.key});

  @override
  Widget build(BuildContext context) => AlertDialog(
    actions: [TextButton(onPressed: () {}, child: const Text('Confirm'))],
  );
}

Future<void> _mount(WidgetTester tester, Widget body) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [TugboatReplay.navigatorObserver],
      builder: (context, child) =>
          TugboatReplay.wrapApp(config: _exploration, child: child!),
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
      expect(wrappedEntries[i]['fingerprint'], plainEntries[i]['fingerprint']);
      expect(
        wrappedEntries[i]['canonicalPath'],
        plainEntries[i]['canonicalPath'],
      );
    }
  });

  testWidgets('TugboatLoading(enabled: false) marks nothing', (tester) async {
    await _mount(
      tester,
      Center(
        child: TugboatLoading(
          enabled: false,
          child: FilledButton(onPressed: () {}, child: const Text('Tile')),
        ),
      ),
    );

    final inventory = _last();
    expect(_elements(inventory), isNotEmpty);
    expect(_loading(inventory)['placeholders'], 0);
    expect(_flagged(inventory), isEmpty);
    for (final entry in _elements(inventory)) {
      expect(entry.containsKey('placeholder'), isFalse);
    }
  });

  testWidgets('toggling TugboatLoading.enabled changes only the flags', (
    tester,
  ) async {
    Future<Map<String, Object?>> inventoryWith({required bool enabled}) async {
      await tester.pumpWidget(const SizedBox());
      TugboatReplay.resetForTest();
      await _mount(
        tester,
        Center(
          child: TugboatLoading(
            enabled: enabled,
            child: FilledButton(onPressed: () {}, child: const Text('Tile')),
          ),
        ),
      );
      return _last();
    }

    final on = await inventoryWith(enabled: true);
    final off = await inventoryWith(enabled: false);

    expect(_loading(on)['placeholders'], 1);
    expect(_flagged(on), hasLength(1));
    expect(_loading(off)['placeholders'], 0);
    expect(_flagged(off), isEmpty);
    expect(off['inventoryHash'], on['inventoryHash']);
    expect(off['routeKey'], on['routeKey']);
    expect(off['surface'], on['surface']);
    final onEntries = _elements(on);
    final offEntries = _elements(off);
    expect(offEntries, hasLength(onEntries.length));
    for (var i = 0; i < onEntries.length; i++) {
      expect(offEntries[i]['fingerprint'], onEntries[i]['fingerprint']);
      expect(offEntries[i]['canonicalPath'], onEntries[i]['canonicalPath']);
    }
  });

  group('the nearest TugboatLoading decides over a skeleton ancestor', () {
    Future<Map<String, Object?>> inventoryUnder(
      WidgetTester tester, {
      bool? enabled,
    }) async {
      final tile = FilledButton(onPressed: () {}, child: const Text('Tile'));
      await _mount(
        tester,
        Center(
          child: SkeletonBox(
            child: enabled == null
                ? tile
                : TugboatLoading(enabled: enabled, child: tile),
          ),
        ),
      );
      return _last();
    }

    testWidgets('a disabled marker beneath it switches the name match off', (
      tester,
    ) async {
      final inventory = await inventoryUnder(tester, enabled: false);

      expect(_elements(inventory), isNotEmpty);
      expect(_loading(inventory)['placeholders'], 0);
      expect(_flagged(inventory), isEmpty);
    });

    testWidgets('an enabled marker beneath it is a placeholder', (
      tester,
    ) async {
      final inventory = await inventoryUnder(tester, enabled: true);

      expect(_loading(inventory)['placeholders'], 1);
      expect(_flagged(inventory), hasLength(1));
    });

    testWidgets('with no marker the name match applies', (tester) async {
      final inventory = await inventoryUnder(tester);

      expect(_loading(inventory)['placeholders'], 1);
      expect(_flagged(inventory), hasLength(1));
    });
  });

  testWidgets('a disabled inner marker beats an enabled outer one', (
    tester,
  ) async {
    await _mount(
      tester,
      Column(
        children: [
          TugboatLoading(
            child: Column(
              children: [
                FilledButton(onPressed: () {}, child: const Text('Outer')),
                TugboatLoading(
                  enabled: false,
                  child: FilledButton(
                    onPressed: () {},
                    child: const Text('Inner'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    final inventory = _last();
    expect(_elements(inventory), hasLength(2));
    expect(_loading(inventory)['placeholders'], 1);
    expect(_flagged(inventory), hasLength(1));
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

  testWidgets('a disabled text field is not a busy control', (tester) async {
    await _mount(tester, const Center(child: TextField(enabled: false)));

    final inventory = _last();
    expect(_elements(inventory), isNotEmpty);
    expect(_loading(inventory)['busyControls'], 0);
  });

  testWidgets('a scope whose type argument names a shimmer marks nothing', (
    tester,
  ) async {
    await _mount(
      tester,
      _Scope<ShimmerController>(
        child: SkeletonTheme(
          child: FilledButton(onPressed: () {}, child: const Text('Live')),
        ),
      ),
    );

    final inventory = _last();
    expect(_loading(inventory)['placeholders'], 0);
    expect(_flagged(inventory), isEmpty);
  });

  testWidgets(
    'a spinner on a route covered by an opaque route is not counted',
    (tester) async {
      await _mount(
        tester,
        Builder(
          builder: (context) => Column(
            children: [
              const CircularProgressIndicator(),
              FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      body: FilledButton(
                        onPressed: () {},
                        child: const Text('Second'),
                      ),
                    ),
                  ),
                ),
                child: const Text('Go'),
              ),
            ],
          ),
        ),
      );
      expect(_loading(_last())['progressIndicators'], 1);

      await tester.tap(find.text('Go'));
      await tester.pump(const Duration(seconds: 1));
      await waitForTugboatCaptureWork(tester);
      await tester.tap(find.text('Second'));
      await tester.pump(const Duration(seconds: 1));
      await waitForTugboatCaptureWork(tester);

      expect(_last()['trigger'], 'tap');
      expect(_loading(_last())['progressIndicators'], 0);
      // The spinner's ticker is off while covered.
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a tap inventory counts busy controls among the entries it keeps',
    (tester) async {
      await _mount(
        tester,
        Column(
          children: [
            FilledButton(onPressed: () {}, child: const Text('Live')),
            const AbsorbPointer(
              child: FilledButton(onPressed: _noop, child: Text('Blocked')),
            ),
          ],
        ),
      );
      expect(_loading(_last())['busyControls'], 1);

      await tester.tap(find.text('Live'));
      await tester.pump(const Duration(milliseconds: 500));
      await waitForTugboatCaptureWork(tester);

      final tap = _inventories().lastWhere((inv) => inv['trigger'] == 'tap');
      final kept = _elements(tap).length;
      expect(_loading(tap)['busyControls'], lessThan(kept));
      expect(_loading(tap)['busyControls'], 0);
    },
  );

  testWidgets('TugboatLoading cannot become a dialog surface widgetClass', (
    tester,
  ) async {
    Future<Map<String, Object?>> dialogInventory(Widget body) async {
      await _mount(
        tester,
        Builder(
          builder: (context) => FilledButton(
            onPressed: () =>
                showDialog<void>(context: context, builder: (_) => body),
            child: const Text('Open'),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pump(const Duration(seconds: 1));
      await waitForTugboatCaptureWork(tester);
      return _inventories().lastWhere(
        (inv) => (inv['surface']! as Map)['kind'] == 'dialog',
      );
    }

    final plain = await dialogInventory(const ConfirmDialog());
    await tester.pumpWidget(const SizedBox());
    TugboatReplay.resetForTest();
    final wrapped = await dialogInventory(
      const TugboatLoading(child: ConfirmDialog()),
    );

    expect((plain['surface']! as Map)['widgetClass'], 'ConfirmDialog');
    expect(wrapped['surface'], plain['surface']);
    expect(wrapped['routeKey'], plain['routeKey']);
    expect(wrapped['inventoryHash'], plain['inventoryHash']);
    expect(_loading(wrapped)['placeholders'], greaterThan(0));
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

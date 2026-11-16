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

// The view is 400x800 logical pixels at devicePixelRatio 2. The capture
// boundary sits 10 px from the left and 30 px from the top, so it measures
// 390x770 and every number below is checkable by hand.
const _dpr = 2.0;
const _boundaryLeft = 10.0;
const _boundaryTop = 30.0;
const _boundaryWidth = 390.0;
const _boundaryHeight = 770.0;

// Page layout, in boundary coordinates: a 100 px header, a list viewport from
// y=100 to y=670, and a 100 px footer. Rows are 80 px tall.
const _listTop = 100.0;
const _listBottom = 670.0;
const _rowExtent = 80.0;
const _initialOffset = 40.0;

void _configureView(WidgetTester tester, {double keyboardPhysical = 0}) {
  tester.view.devicePixelRatio = _dpr;
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.viewPadding = const FakeViewPadding(
    top: 96,
    bottom: 68,
    left: 6,
    right: 10,
  );
  tester.view.padding = const FakeViewPadding(
    top: 96,
    bottom: 68,
    left: 6,
    right: 10,
  );
  if (keyboardPhysical > 0) {
    tester.view.viewInsets = FakeViewPadding(bottom: keyboardPhysical);
  }
  addTearDown(tester.view.reset);
}

Widget _listPage(ScrollController controller) => Scaffold(
  body: Stack(
    clipBehavior: Clip.none,
    children: [
      Column(
        children: [
          SizedBox(
            height: _listTop,
            child: Center(
              child: FilledButton(onPressed: () {}, child: const Text('Top')),
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: controller,
              // No safe-area padding: rows start exactly at the list's top.
              padding: EdgeInsets.zero,
              itemExtent: _rowExtent,
              itemCount: 30,
              itemBuilder: (_, i) =>
                  ListTile(onTap: () {}, title: Text('Row $i')),
            ),
          ),
          SizedBox(
            height: 100,
            child: Center(
              child: FilledButton(
                onPressed: () {},
                child: const Text('Bottom'),
              ),
            ),
          ),
        ],
      ),
      // Sticks 20 px out of the left edge of the capture boundary.
      Positioned(
        left: -20,
        top: 300,
        width: 100,
        height: 50,
        child: FilledButton(onPressed: () {}, child: const Text('Edge')),
      ),
    ],
  ),
);

Future<void> _mount(WidgetTester tester, Widget home) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [TugboatReplay.navigatorObserver],
      builder: (context, child) => Padding(
        padding: const EdgeInsets.only(left: _boundaryLeft, top: _boundaryTop),
        child: TugboatReplay.wrapApp(config: _exploration, child: child!),
      ),
      home: home,
    ),
  );
  await waitForTugboatCaptureWork(tester);
}

List<Map<String, Object?>> _inventories() => [
  for (final event in TugboatReplay.controller!.session!.events)
    if (event.type == 'scene_inventory') event.data,
];

List<Map<String, Object?>> _elements(Map<String, Object?> inventory) => [
  for (final e in inventory['elements']! as List) (e as Map).cast(),
];

Map<String, Object?> _map(Object? value) => (value! as Map).cast();

/// The interactive full-width entry for list row [index]. Rows are told apart
/// by position (row `i` starts at `_rowTop(i)`): the resolved widget type of a
/// row depends on where its hit test lands, and text is never emitted.
Map<String, Object?> _row(Map<String, Object?> inventory, int index) =>
    _elements(inventory).firstWhere(
      (e) =>
          e['tier'] == 'interactive' &&
          (_top(e) * _boundaryHeight - _rowTop(index)).abs() < 0.5 &&
          (_map(e['boundsNorm'])['width']! as double) > 0.99,
    );

/// Row `index` starts this far down the boundary at the initial offset.
double _rowTop(int index) => _listTop - _initialOffset + index * _rowExtent;

double _top(Map<String, Object?> entry) =>
    _map(entry['boundsNorm'])['top']! as double;

double _left(Map<String, Object?> entry) =>
    _map(entry['boundsNorm'])['left']! as double;

/// Interactive entries that are not list rows: the header button, the footer
/// button and the one sticking out of the boundary. Text is never emitted, so
/// they are told apart by position.
List<Map<String, Object?>> _buttons(Map<String, Object?> inventory) => [
  for (final e in _elements(inventory))
    if (e['tier'] == 'interactive' &&
        (_map(e['boundsNorm'])['width']! as double) < 0.99)
      e,
];

Map<String, Object?> _edgeButton(Map<String, Object?> inventory) =>
    _buttons(inventory).firstWhere((e) => _left(e) < 0);

Map<String, Object?> _headerButton(Map<String, Object?> inventory) =>
    _buttons(inventory).firstWhere((e) => _left(e) >= 0 && _top(e) < 0.1);

/// Large text blocks lower than [fromY] boundary pixels: the labels of rows
/// that are built under the footer.
List<Map<String, Object?>> _textsBelow(
  Map<String, Object?> inventory,
  double fromY,
) => [
  for (final e in _elements(inventory))
    if (e['tier'] == 'content' && _top(e) * _boundaryHeight >= fromY) e,
];

double _norm(double value, double size) => value / size;

void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('every inventory carries the viewport it was measured in', (
    tester,
  ) async {
    _configureView(tester);
    final controller = ScrollController(initialScrollOffset: _initialOffset);
    addTearDown(controller.dispose);
    await _mount(tester, _listPage(controller));

    final viewport = _map(_inventories().last['viewport']);

    expect(viewport, {
      'widthPx': _boundaryWidth,
      'heightPx': _boundaryHeight,
      'devicePixelRatio': _dpr,
      'boundaryOffset': {'left': _boundaryLeft, 'top': _boundaryTop},
      // Physical 96/68/6/10 at ratio 2.
      'insets': {'top': 48.0, 'bottom': 34.0, 'left': 3.0, 'right': 5.0},
      'keyboardInset': 0.0,
      'referenceFrame': 'captureBoundary',
    });
    for (final inventory in _inventories()) {
      expect(inventory['viewport'], isNotNull);
    }
  });

  testWidgets('keyboardInset reports the bottom view inset in logical px', (
    tester,
  ) async {
    _configureView(tester, keyboardPhysical: 600);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await _mount(tester, _listPage(controller));

    expect(_map(_inventories().last['viewport'])['keyboardInset'], 300.0);
  });

  testWidgets('a row half scrolled out of the list reports visibleFraction', (
    tester,
  ) async {
    _configureView(tester);
    final controller = ScrollController(initialScrollOffset: _initialOffset);
    addTearDown(controller.dispose);
    await _mount(tester, _listPage(controller));
    final inventory = _inventories().last;

    // Row 0 spans y=60..140 in the boundary; the list shows it from y=100.
    final half = _row(inventory, 0);
    expect(half['visibleFraction'] as double, closeTo(0.5, 0.001));

    // boundsNorm stays the unclipped paint box.
    final bounds = _map(half['boundsNorm']);
    expect(bounds['top'], closeTo(_norm(_listTop - 40, _boundaryHeight), 1e-9));
    expect(bounds['height'], closeTo(_norm(_rowExtent, _boundaryHeight), 1e-9));
    expect(bounds['left'], closeTo(0, 1e-9));
    expect(bounds['width'], closeTo(1, 1e-9));

    // A row fully inside the list says nothing.
    final whole = _row(inventory, 2);
    expect(whole.containsKey('visibleFraction'), isFalse);
  });

  testWidgets('rows cut by the bottom of the list or below it report it', (
    tester,
  ) async {
    _configureView(tester);
    final controller = ScrollController(initialScrollOffset: _initialOffset);
    addTearDown(controller.dispose);
    await _mount(tester, _listPage(controller));
    final inventory = _inventories().last;

    // Row 7 spans y=620..700; the list ends at 670.
    final cut = _row(inventory, 7);
    expect(
      cut['visibleFraction'] as double,
      closeTo((_listBottom - 620) / _rowExtent, 0.001),
    );

    // Row 8 is built (cache extent) and lies under the footer, inside the
    // boundary but outside the list's viewport: nothing of it is visible, yet
    // it is still listed with its box, and so is its label.
    final hidden = _row(inventory, 8);
    expect(hidden['visibleFraction'], 0.0);
    expect(_top(hidden) * _boundaryHeight, closeTo(_rowTop(8), 0.01));
    final labels = _textsBelow(inventory, _listBottom);
    expect(labels, isNotEmpty);
    for (final label in labels) {
      expect(label['visibleFraction'], 0.0);
    }
  });

  testWidgets('an element sticking out of the boundary is partly visible', (
    tester,
  ) async {
    _configureView(tester);
    final controller = ScrollController(initialScrollOffset: _initialOffset);
    addTearDown(controller.dispose);
    await _mount(tester, _listPage(controller));

    final edge = _edgeButton(_inventories().last);

    expect(_map(edge['boundsNorm'])['left'], lessThan(0));
    expect(edge['visibleFraction'] as double, closeTo(0.8, 0.001));
    // The header button is whole.
    expect(
      _headerButton(_inventories().last).containsKey('visibleFraction'),
      isFalse,
    );
  });

  testWidgets('scroll reports the offset and extent of the list', (
    tester,
  ) async {
    _configureView(tester);
    final controller = ScrollController(initialScrollOffset: _initialOffset);
    addTearDown(controller.dispose);
    await _mount(tester, _listPage(controller));

    final scroll = _map(_inventories().last['scroll']);

    expect(scroll['offsetPx'], controller.offset);
    expect(scroll['offsetPx'], _initialOffset);
    expect(scroll['maxExtentPx'], controller.position.maxScrollExtent);
    expect(scroll['maxExtentPx'], 30 * _rowExtent - (_listBottom - _listTop));
    expect(scroll['axis'], 'vertical');
  });

  testWidgets('a scrolled list reports its new offset', (tester) async {
    _configureView(tester);
    final controller = ScrollController(initialScrollOffset: _initialOffset);
    addTearDown(controller.dispose);
    await _mount(tester, _listPage(controller));
    final before = _inventories().length;

    controller.jumpTo(500);
    await tester.pumpAndSettle();
    await waitForTugboatCaptureWork(tester);

    final inventories = _inventories();
    expect(inventories.length, greaterThan(before));
    final scroll = _map(inventories.last['scroll']);
    expect(scroll['offsetPx'], 500.0);
    expect(scroll['offsetPx'], controller.offset);
  });

  testWidgets('the larger vertical scrollable is the primary one', (
    tester,
  ) async {
    _configureView(tester);
    final small = ScrollController(initialScrollOffset: 10);
    final large = ScrollController(initialScrollOffset: 30);
    addTearDown(small.dispose);
    addTearDown(large.dispose);
    await _mount(
      tester,
      Scaffold(
        body: Column(
          children: [
            SizedBox(
              height: 200,
              child: ListView.builder(
                controller: small,
                itemCount: 20,
                itemBuilder: (_, i) =>
                    ListTile(onTap: () {}, title: Text('S$i')),
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: large,
                itemCount: 40,
                itemBuilder: (_, i) =>
                    ListTile(onTap: () {}, title: Text('L$i')),
              ),
            ),
            SizedBox(
              height: 60,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: const [SizedBox(width: 900)],
              ),
            ),
          ],
        ),
      ),
    );

    expect(_map(_inventories().last['scroll'])['offsetPx'], 30.0);
  });

  testWidgets('a sheet over a scrolled page does not report the page scroll', (
    tester,
  ) async {
    _configureView(tester);
    final controller = ScrollController(initialScrollOffset: _initialOffset);
    addTearDown(controller.dispose);
    await _mount(tester, _listPage(controller));

    showModalBottomSheet<void>(
      context: tester.element(find.byType(Scaffold).first),
      builder: (_) => Center(
        child: FilledButton(onPressed: () {}, child: const Text('Sheet')),
      ),
    );
    await tester.pumpAndSettle();
    await waitForTugboatCaptureWork(tester);

    final sheet = _inventories().lastWhere(
      (i) => _map(i['surface'])['kind'] == 'sheet',
    );
    expect(sheet.containsKey('scroll'), isFalse);
    expect(sheet['viewport'], isNotNull);
  });

  testWidgets('a page without a vertical scrollable has no scroll', (
    tester,
  ) async {
    _configureView(tester);
    await _mount(
      tester,
      Scaffold(
        body: Center(
          child: FilledButton(onPressed: () {}, child: const Text('Only')),
        ),
      ),
    );
    final inventory = _inventories().last;

    expect(inventory.containsKey('scroll'), isFalse);
    expect(inventory['viewport'], isNotNull);
    for (final element in _elements(inventory)) {
      expect(element.containsKey('visibleFraction'), isFalse);
    }
  });

  testWidgets('the evidence never enters the hash or the fingerprints', (
    tester,
  ) async {
    _configureView(tester);
    final controller = ScrollController(initialScrollOffset: _initialOffset);
    addTearDown(controller.dispose);
    await _mount(tester, _listPage(controller));
    final inventory = _inventories().last;
    final fingerprints = [
      for (final e in _elements(inventory)) e['fingerprint']! as String,
    ]..sort();

    expect(
      inventory['inventoryHash'],
      tugboatLabelHash(fingerprints.join('|')),
    );
    // Clipped rows are still in the inventory with their unclipped boxes: the
    // half-visible row and the label under the footer are both listed.
    expect(_row(inventory, 0)['boundsNorm'], isNotNull);
    expect(_textsBelow(inventory, _listBottom), isNotEmpty);
  });
}

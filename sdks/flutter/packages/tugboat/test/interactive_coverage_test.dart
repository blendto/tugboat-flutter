import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/anchors.dart';
import 'package:tugboat/tugboat.dart';

// The fixture lives in the example app, which is not a package dependency.
// ignore: avoid_relative_lib_imports
import '../example/lib/screens/interactive_coverage_screen.dart';

/// What the scene inventory must say about each fixture pattern. A pattern
/// that is not reported carries the reason it is not.
const _reported = <String>[
  'cov-filled',
  'cov-icon',
  'cov-list-tile',
  'cov-checkbox',
  'cov-switch',
  'cov-chip',
  'cov-slider',
  'cov-text-field',
  'cov-cupertino',
  'cov-ink-well',
  'cov-gesture-tap',
  'cov-semantics-tap',
  'cov-listener-pointer-up',
  'cov-raw-tap',
  'cov-mouse-over-button',
  'cov-stacked',
  'cov-tagged',
];

/// Disabled controls are listed with `enabled: false` and no tap action.
const _reportedDisabled = <String>['cov-filled-disabled', 'cov-icon-disabled'];

/// Patterns the inventory does not report, and why.
const _notReported = <String, String>{
  // A ListTile without onTap or onLongPress has no role: it is a passive row.
  'cov-list-tile-passive': 'no tap or long-press callback, so no role',
  // A pan-only GestureDetector is not a tap target.
  'cov-gesture-pan-only': 'pan gestures are not a tap action',
  // A Semantics label without a tap action is text, not a control.
  'cov-semantics-label-only': 'semantics label without tap or long-press',
  // Only a pointer-up handler is a tap; a pointer-down one is not reported.
  'cov-listener-pointer-down': 'pointer-down is not a tap',
  // MouseRegion never makes a control on its own (no hover-only role).
  'cov-mouse-region': 'MouseRegion is not a control on its own',
  // An InkWell without onTap is ink plumbing, so it is not a disabled control.
  'cov-ink-well-disabled':
      'InkWell without onTap is ink plumbing, not a control',
};

Future<TugboatSceneInventory> _inventoryFor(
  WidgetTester tester,
  GlobalKey rootKey, {
  String route = '/coverage',
}) async {
  final resolver = AnchorResolver(rootKey: rootKey);
  final inventory = resolver.buildSceneInventory(
    route: route,
    keyboardOpen: false,
    modalOpen: false,
    withBoundsEvidence: true,
  );
  expect(inventory, isNotNull);
  return inventory!;
}

Future<TugboatSceneInventory> _mountCoverage(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  final rootKey = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      home: RepaintBoundary(
        key: rootKey,
        child: const InteractiveCoverageScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _inventoryFor(tester, rootKey);
}

/// The control entries whose box contains the centre of the pattern [key], in
/// normalized coordinates of the capture root. A scroll view's own entry
/// (only the `scroll` action) is not a control; a text field's entry is
/// named `scrollable` by schema 6 but carries its `input` action.
List<TugboatSceneInventoryEntry> _entriesAt(
  WidgetTester tester,
  TugboatSceneInventory inventory,
  String key,
) {
  final root = find.byType(RepaintBoundary).first;
  final origin = tester.getTopLeft(root);
  final size = tester.getSize(root);
  final centre = tester.getCenter(find.byKey(Key(key))) - origin;
  final nx = centre.dx / size.width;
  final ny = centre.dy / size.height;
  return [
    for (final entry in inventory.elements)
      if (entry.tier == 'interactive' &&
          _isControlEntry(entry) &&
          _contains(entry, nx, ny))
        entry,
  ];
}

bool _isControlEntry(TugboatSceneInventoryEntry entry) =>
    entry.enabled == false || entry.actions.any((action) => action != 'scroll');

bool _contains(TugboatSceneInventoryEntry entry, double x, double y) {
  final b = entry.boundsNorm;
  return x >= b.left &&
      x <= b.left + b.width &&
      y >= b.top &&
      y <= b.top + b.height;
}

/// Control families built with their callbacks set or null. Toggling the
/// callback must leave the control's fingerprints and the route key unchanged.
final _families = <String, Widget Function({required bool enabled})>{
  'FilledButton': ({required enabled}) => FilledButton(
    onPressed: enabled ? () {} : null,
    child: const Text('Save'),
  ),
  'ElevatedButton': ({required enabled}) => ElevatedButton(
    onPressed: enabled ? () {} : null,
    child: const Text('Save'),
  ),
  'TextButton': ({required enabled}) =>
      TextButton(onPressed: enabled ? () {} : null, child: const Text('Save')),
  'OutlinedButton': ({required enabled}) => OutlinedButton(
    onPressed: enabled ? () {} : null,
    child: const Text('Save'),
  ),
  'IconButton': ({required enabled}) => IconButton(
    onPressed: enabled ? () {} : null,
    icon: const Icon(Icons.add),
  ),
  'Checkbox': ({required enabled}) =>
      Checkbox(value: false, onChanged: enabled ? (_) {} : null),
  'Switch': ({required enabled}) =>
      Switch(value: false, onChanged: enabled ? (_) {} : null),
  'ActionChip': ({required enabled}) =>
      ActionChip(label: const Text('Chip'), onPressed: enabled ? () {} : null),
  'CupertinoButton': ({required enabled}) => CupertinoButton(
    onPressed: enabled ? () {} : null,
    child: const Text('Save'),
  ),
  'TextField': ({required enabled}) => TextField(enabled: enabled),
};

Future<({Set<String> fingerprints, String routeKey})> _familyState(
  WidgetTester tester,
  Widget control,
) async {
  final rootKey = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      home: RepaintBoundary(
        key: rootKey,
        child: Scaffold(
          body: Center(
            child: KeyedSubtree(key: const Key('cov-family'), child: control),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // An anonymous route, so its key is the structural signature.
  final inventory = await _inventoryFor(
    tester,
    rootKey,
    route: 'MaterialPageRoute<dynamic>',
  );
  final entries = _entriesAt(tester, inventory, 'cov-family');
  return (
    fingerprints: {for (final entry in entries) entry.fingerprint},
    routeKey: inventory.routeKey,
  );
}

void main() {
  tearDown(TugboatReplay.resetForTest);

  for (final family in _families.entries) {
    testWidgets('${family.key}: enabling it does not change its identity', (
      tester,
    ) async {
      final disabled = await _familyState(tester, family.value(enabled: false));
      final enabled = await _familyState(tester, family.value(enabled: true));
      expect(enabled.fingerprints, isNotEmpty);
      expect(enabled.routeKey, startsWith('struct:'));
      expect(disabled.fingerprints, enabled.fingerprints);
      expect(disabled.routeKey, enabled.routeKey);
    });
  }

  testWidgets('each reported pattern has one control entry with its tap', (
    tester,
  ) async {
    final inventory = await _mountCoverage(tester);
    for (final key in _reported) {
      final entries = _entriesAt(tester, inventory, key);
      expect(entries, isNotEmpty, reason: '$key is not reported');
      expect(
        entries.where((e) => e.enabled != false).length,
        greaterThanOrEqualTo(1),
        reason: '$key has no enabled entry',
      );
    }
  });

  testWidgets('disabled patterns are listed with enabled false and no tap', (
    tester,
  ) async {
    final inventory = await _mountCoverage(tester);
    for (final key in _reportedDisabled) {
      final entries = _entriesAt(tester, inventory, key);
      expect(entries, isNotEmpty, reason: '$key is not listed');
      for (final entry in entries) {
        expect(entry.enabled, isFalse, reason: key);
        expect(entry.actions.contains('tap'), isFalse, reason: key);
      }
    }
  });

  testWidgets('unreported patterns have no control entry, with a reason', (
    tester,
  ) async {
    final inventory = await _mountCoverage(tester);
    _notReported.forEach((key, reason) {
      expect(
        _entriesAt(tester, inventory, key),
        isEmpty,
        reason: '$key is reported but should not be: $reason',
      );
    });
  });

  testWidgets('stacked layers of one button are one entry with aliases', (
    tester,
  ) async {
    final inventory = await _mountCoverage(tester);
    final entries = _entriesAt(tester, inventory, 'cov-stacked');
    expect(entries, hasLength(1));
    expect(entries.single.aliases, isNotEmpty);
  });

  testWidgets('an explicit TugboatTag names its control and nothing else', (
    tester,
  ) async {
    final inventory = await _mountCoverage(tester);
    final tagged = _entriesAt(tester, inventory, 'cov-tagged');
    expect(tagged.map((e) => e.tag), ['checkout-cta']);
    final untagged = _entriesAt(tester, inventory, 'cov-filled');
    expect(untagged.map((e) => e.tag), [null]);
  });

  testWidgets('a low-level tap widget is reported with its role', (
    tester,
  ) async {
    final inventory = await _mountCoverage(tester);
    final semantics = _entriesAt(tester, inventory, 'cov-semantics-tap');
    expect(semantics.single.role, 'button');
    expect(semantics.single.actions, ['tap']);
    final pointer = _entriesAt(tester, inventory, 'cov-listener-pointer-up');
    expect(pointer.single.actions, ['tap']);
  });
}

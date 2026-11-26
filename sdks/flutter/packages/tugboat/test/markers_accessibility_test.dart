import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/anchors.dart';
import 'package:tugboat/tugboat.dart';

typedef _Control = Widget Function();

/// One semantics node in depth-first order, including its identifier.
class _Node {
  const _Node({
    required this.label,
    required this.value,
    required this.hint,
    required this.tooltip,
    required this.identifier,
    required this.flags,
    required this.actions,
    required this.focusable,
  });

  final String label;
  final String value;
  final String hint;
  final String tooltip;
  final String identifier;
  final int flags;
  final int actions;
  final bool focusable;

  /// Everything a screen reader reads, without depth or the identifier.
  String get readable =>
      '$label|$value|$hint|$tooltip|$flags|$actions|focusable=$focusable';

  bool get hasIdentifier => identifier.isNotEmpty;
}

/// Whether a node is focusable, across Flutter SDK versions.
///
/// Flutter 3.35 and earlier expose a bool `isFocused` (focused now) next to a
/// separate bool `isFocusable`. Flutter 3.36+ replaces them with a single
/// [Tristate] `isFocused`, where `none` means the node is not focusable.
bool _isFocusable(SemanticsFlags flags) {
  final dynamic state = flags;
  final focused = state.isFocused;
  if (focused is bool) return state.isFocusable == true;
  return focused.toBoolOrNull() != null;
}

List<_Node> _snapshot(WidgetTester tester) {
  final root = tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!;
  final nodes = <_Node>[];
  void walk(SemanticsNode node) {
    final data = node.getSemanticsData();
    nodes.add(
      _Node(
        label: data.label,
        value: data.value,
        hint: data.hint,
        tooltip: data.tooltip,
        identifier: data.identifier,
        // ignore: deprecated_member_use
        flags: data.flags,
        actions: data.actions,
        focusable: _isFocusable(data.flagsCollection),
      ),
    );
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(root);
  return nodes;
}

List<_Node> _focusable(List<_Node> nodes) =>
    nodes.where((node) => node.focusable).toList();

List<_Node> _identified(List<_Node> nodes) =>
    nodes.where((node) => node.hasIdentifier).toList();

Future<List<_Node>> _pumpAndSnapshot(
  WidgetTester tester,
  Widget control,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: control)),
    ),
  );
  await tester.pump();
  return _snapshot(tester);
}

void main() {
  // Single-control cases. `carriesLabel` is true when the plain Semantics
  // identifier lands on the control's own node (no extra node). Material
  // buttons get a separate, label-less container node instead, so the
  // identifier does not sit on the labelled button. That is recorded below.
  final cases = <String, (_Control, bool)>{
    'ElevatedButton': (
      () => ElevatedButton(onPressed: () {}, child: const Text('Pay')),
      false,
    ),
    'TextButton': (
      () => TextButton(onPressed: () {}, child: const Text('Skip')),
      false,
    ),
    'FilledButton': (
      () => FilledButton(onPressed: () {}, child: const Text('Save')),
      false,
    ),
    'OutlinedButton': (
      () => OutlinedButton(onPressed: () {}, child: const Text('Cancel')),
      false,
    ),
    'IconButton with tooltip': (
      () => IconButton(
        icon: const Icon(Icons.add),
        tooltip: 'Add item',
        onPressed: () {},
      ),
      false,
    ),
    'ListTile with onTap': (
      () => ListTile(title: const Text('Order history'), onTap: () {}),
      true,
    ),
    'Checkbox': (() => Checkbox(value: false, onChanged: (_) {}), true),
    'Switch': (() => Switch(value: false, onChanged: (_) {}), true),
    'TextField': (
      () => const SizedBox(
        width: 200,
        child: TextField(decoration: InputDecoration(labelText: 'Email')),
      ),
      true,
    ),
    'GestureDetector around Text': (
      () => GestureDetector(onTap: () {}, child: const Text('Tap me')),
      true,
    ),
    'InkWell around Text': (
      () => InkWell(onTap: () {}, child: const Text('Ink me')),
      true,
    ),
  };

  for (final entry in cases.entries) {
    final (build, carriesLabel) = entry.value;
    testWidgets('semantics gate: ${entry.key}', (tester) async {
      final handle = tester.ensureSemantics();

      final untagged = await _pumpAndSnapshot(tester, build());

      // Default (accessibility: false) must be indistinguishable from no tag.
      final defaults = await _pumpAndSnapshot(
        tester,
        build().tugboatTag('checkout'),
      );
      expect(
        defaults.map((node) => node.readable).toList(),
        untagged.map((node) => node.readable).toList(),
        reason: 'default tag changed the semantics tree',
      );
      expect(_identified(defaults), isEmpty);

      // Opt-in (accessibility: true): exactly one node carries the id.
      final accessible = await _pumpAndSnapshot(
        tester,
        build().tugboatTag('checkout', accessibility: true),
      );
      final identified = _identified(accessible);
      expect(identified.map((node) => node.identifier), ['checkout']);
      expect(
        _focusable(accessible).length,
        _focusable(untagged).length,
        reason: 'focusable node count changed',
      );

      // The control node is the one that carries actions (GestureDetector
      // and InkWell-free wrappers may not be focusable).
      final control = untagged.where((node) => node.actions != 0).single;
      if (carriesLabel) {
        final idNode = identified.single;
        expect(idNode.label, control.label);
        expect(idNode.flags, control.flags);
        expect(idNode.actions, control.actions);
      } else {
        // Known limitation: the id sits on a label-less container, and the
        // labelled button node stays unidentified beneath it.
        expect(identified.single.label, isEmpty);
        expect(identified.single.actions, 0);
      }
      handle.dispose();
    });
  }

  testWidgets('semantics gate: container of two TextButtons (opt-in)', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    Widget row() => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(onPressed: () {}, child: const Text('One')),
        TextButton(onPressed: () {}, child: const Text('Two')),
      ],
    );

    final untagged = await _pumpAndSnapshot(tester, row());
    final accessible = await _pumpAndSnapshot(
      tester,
      row().tugboatTag('checkout', accessibility: true),
    );

    // Recorded result: the buttons are not merged into one node. The id goes
    // on a label-less wrapper above both buttons, which keep their own nodes.
    expect(_identified(accessible).single.label, isEmpty);
    expect(
      _focusable(accessible).map((node) => node.label),
      _focusable(untagged).map((node) => node.label),
    );
    expect(_focusable(accessible).length, 2);
    handle.dispose();
  });

  testWidgets('untagged ElevatedButton exposes a focusable node', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    final snapshot = await _pumpAndSnapshot(
      tester,
      ElevatedButton(onPressed: () {}, child: const Text('Pay')),
    );

    // Guards the focusable-count assertions above against a helper that
    // reports false for every node.
    expect(_focusable(snapshot), isNotEmpty);
    handle.dispose();
  });

  testWidgets('accessibility: false adds no semantics identifier', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    final snapshot = await _pumpAndSnapshot(
      tester,
      ElevatedButton(
        onPressed: () {},
        child: const Text('Pay'),
      ).tugboatTag('checkout', accessibility: false),
    );

    expect(_identified(snapshot), isEmpty);
    handle.dispose();
  });

  testWidgets('TugboatTag wrapper exposes the identifier like the extension', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    final snapshot = await _pumpAndSnapshot(
      tester,
      TugboatTag(
        'checkout',
        accessibility: true,
        child: ListTile(title: const Text('Order history'), onTap: () {}),
      ),
    );

    expect(_identified(snapshot).map((node) => node.identifier), ['checkout']);
    handle.dispose();
  });

  testWidgets('accessibility option does not change target or state identity', (
    tester,
  ) async {
    final rootKey = GlobalKey();

    Future<({TugboatTargetAnchor anchor, int? state})> capture(
      Widget control,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: rootKey,
            child: Scaffold(body: Center(child: control)),
          ),
        ),
      );
      await tester.pump();
      final resolver = AnchorResolver(rootKey: rootKey);
      final center = tester.getCenter(find.text('Pay now'));
      return (
        anchor: resolver.targetAt(center)!,
        state: resolver.structureSignature(
          rootRender: rootKey.currentContext!.findRenderObject()! as RenderBox,
        ),
      );
    }

    Widget button() =>
        ElevatedButton(onPressed: () {}, child: const Text('Pay now'));

    final baseline = await capture(button());
    final withAccessibility = await capture(
      button().tugboatTag('checkout-cta', accessibility: true),
    );
    final withoutAccessibility = await capture(
      button().tugboatTag('checkout-cta', accessibility: false),
    );

    // The tag alias itself is the only intended difference from baseline.
    expect(withAccessibility.anchor.fingerprint, baseline.anchor.fingerprint);
    expect(
      withAccessibility.anchor.canonicalPath,
      baseline.anchor.canonicalPath,
    );
    expect(withAccessibility.state, baseline.state);

    // The Semantics node the SDK inserts must not leak into identity.
    expect(
      withAccessibility.anchor.fingerprint,
      withoutAccessibility.anchor.fingerprint,
    );
    expect(
      withAccessibility.anchor.canonicalPath,
      withoutAccessibility.anchor.canonicalPath,
    );
    expect(
      withAccessibility.anchor.tagFingerprint,
      withoutAccessibility.anchor.tagFingerprint,
    );
    expect(withAccessibility.state, withoutAccessibility.state);
    expect(
      withAccessibility.anchor.fingerprintParts,
      withoutAccessibility.anchor.fingerprintParts,
    );
  });
}

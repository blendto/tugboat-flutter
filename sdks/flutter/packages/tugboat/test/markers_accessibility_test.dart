import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/anchors.dart';
import 'package:tugboat/tugboat.dart';

typedef _Control = Widget Function();

class _Snapshot {
  const _Snapshot({
    required this.nodes,
    required this.focusable,
    required this.identifiers,
  });

  /// One descriptor per semantics node, excluding the identifier.
  final List<String> nodes;
  final int focusable;
  final List<String> identifiers;
}

_Snapshot _snapshot(WidgetTester tester) {
  final root = tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!;
  final nodes = <String>[];
  final identifiers = <String>[];
  var focusable = 0;
  void walk(SemanticsNode node, int depth) {
    final data = node.getSemanticsData();
    if (data.identifier case final id? when id.isNotEmpty) {
      identifiers.add(id);
    }
    if (data.flagsCollection.isFocused != ui.Tristate.none) focusable++;
    // Flags and actions are read from the bitmasks so the descriptor is a
    // plain string; the identifier is intentionally left out of it.
    // ignore: deprecated_member_use
    final flags = data.flags;
    final actions = data.actions;
    nodes.add(
      '$depth|${data.label}|${data.value}|${data.hint}|${data.tooltip}'
      '|$flags|$actions',
    );
    node.visitChildren((child) {
      walk(child, depth + 1);
      return true;
    });
  }

  walk(root, 0);
  return _Snapshot(
    nodes: nodes,
    focusable: focusable,
    identifiers: identifiers,
  );
}

Future<_Snapshot> _pumpAndSnapshot(WidgetTester tester, Widget control) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: control)),
    ),
  );
  await tester.pump();
  return _snapshot(tester);
}

void main() {
  final cases = <String, _Control>{
    'ElevatedButton': () =>
        ElevatedButton(onPressed: () {}, child: const Text('Pay')),
    'TextButton': () => TextButton(onPressed: () {}, child: const Text('Skip')),
    'IconButton with tooltip': () => IconButton(
      icon: const Icon(Icons.add),
      tooltip: 'Add item',
      onPressed: () {},
    ),
    'ListTile with onTap': () => ListTile(
      title: const Text('Order history'),
      subtitle: const Text('Last 30 days'),
      onTap: () {},
    ),
    'Checkbox': () => Checkbox(value: false, onChanged: (_) {}),
    'Switch': () => Switch(value: false, onChanged: (_) {}),
    'TextField': () => const SizedBox(
      width: 200,
      child: TextField(
        decoration: InputDecoration(labelText: 'Email', hintText: 'you@x.com'),
      ),
    ),
    'GestureDetector around Text': () =>
        GestureDetector(onTap: () {}, child: const Text('Tap me')),
    'InkWell around Text': () =>
        InkWell(onTap: () {}, child: const Text('Ink me')),
  };

  // Controls whose semantics change when the identifier is published. The
  // SDK-inserted Semantics node splits the label/flags from the Material
  // button node, so the button is no longer one screen-reader node. This is
  // why `accessibility` is opt-in.
  const splitsWhenAccessible = {
    'ElevatedButton',
    'TextButton',
    'IconButton with tooltip',
  };

  for (final entry in cases.entries) {
    testWidgets('screen-reader gate: ${entry.key}', (tester) async {
      final handle = tester.ensureSemantics();

      final untagged = await _pumpAndSnapshot(tester, entry.value());

      // Default (accessibility: false) must be indistinguishable from no tag.
      final defaults = await _pumpAndSnapshot(
        tester,
        entry.value().tugboatTag('checkout'),
      );
      expect(defaults.nodes, untagged.nodes, reason: 'default changed');
      expect(defaults.focusable, untagged.focusable);
      expect(defaults.identifiers, isEmpty);

      // Opt-in (accessibility: true): only the identifier may be added.
      final accessible = await _pumpAndSnapshot(
        tester,
        entry.value().tugboatTag('checkout', accessibility: true),
      );
      expect(accessible.identifiers, ['checkout']);
      if (splitsWhenAccessible.contains(entry.key)) {
        expect(
          accessible.nodes,
          isNot(untagged.nodes),
          reason: 'documented split no longer reproduces',
        );
      } else {
        expect(accessible.nodes, untagged.nodes, reason: 'semantics changed');
        expect(accessible.focusable, untagged.focusable);
      }
      handle.dispose();
    });
  }

  testWidgets('default and accessibility: false add no semantics identifier', (
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

    expect(snapshot.identifiers, isEmpty);
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
        child: ElevatedButton(onPressed: () {}, child: const Text('Pay')),
      ),
    );

    expect(snapshot.identifiers, ['checkout']);
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

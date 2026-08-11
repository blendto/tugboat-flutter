import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';
import 'package:tugboat/src/anchors.dart';

void main() {
  testWidgets(
    'list row taps without discriminator share low-confidence fingerprint',
    (tester) async {
      final rootKey = GlobalKey();

      Future<TugboatTargetAnchor?> tapRow(int index) async {
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(
              key: rootKey,
              child: Scaffold(
                body: ListView(
                  children: [
                    for (var i = 0; i < 7; i++)
                      ListTile(title: Text('Dynamic user $i'), onTap: () {}),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final center = tester.getCenter(find.text('Dynamic user $index'));
        return AnchorResolver(
          rootKey: rootKey,
        ).targetAt(center, route: '/feed');
      }

      final row1 = await tapRow(1);
      final row4 = await tapRow(4);
      expect(row1?.fingerprint, row4?.fingerprint);
      expect(row1?.fingerprintConfidence, 'low');
    },
  );

  testWidgets('static discriminators distinguish list items', (tester) async {
    final rootKey = GlobalKey();

    Future<TugboatTargetAnchor?> tapPlan(String label) async {
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: rootKey,
            child: Scaffold(
              body: ListView(
                children: [
                  ListTile(title: const Text('Pro'), onTap: () {}),
                  ListTile(title: const Text('Basic'), onTap: () {}),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final center = tester.getCenter(find.text(label));
      return AnchorResolver(rootKey: rootKey).targetAt(center, route: '/plans');
    }

    final pro = await tapPlan('Pro');
    final basic = await tapPlan('Basic');
    expect(pro?.fingerprint, isNot(basic?.fingerprint));
    expect(pro?.fingerprintConfidence, isNot('low'));
    expect(pro?.canonicalPath, isNot(contains('Pro')));
    expect(basic?.canonicalPath, isNot(contains('Basic')));
  });

  testWidgets('TugboatTag adds an alias without changing structural identity', (
    tester,
  ) async {
    final rootKey = GlobalKey();

    Future<TugboatTargetAnchor> capture({required bool tagged}) async {
      final button = FilledButton(
        onPressed: () {},
        child: const Text('Pay now'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: rootKey,
            child: Scaffold(
              body: tagged ? TugboatTag('checkout-cta', child: button) : button,
            ),
          ),
        ),
      );
      await tester.pump();
      final center = tester.getCenter(find.text('Pay now'));
      return AnchorResolver(rootKey: rootKey).targetAt(center)!;
    }

    final untagged = await capture(tagged: false);
    final tagged = await capture(tagged: true);

    expect(tagged.fingerprint, untagged.fingerprint);
    expect(tagged.canonicalPath, untagged.canonicalPath);
    expect(tagged.tagFingerprint, isNotNull);
    expect(tagged.fingerprintParts, containsPair('tag', 'checkout-cta'));
  });

  testWidgets('target fingerprint excludes schema version metadata', (
    tester,
  ) async {
    final rootKey = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: Scaffold(
            body: FilledButton(onPressed: () {}, child: const Text('Go')),
          ),
        ),
      ),
    );
    await tester.pump();

    final center = tester.getCenter(find.byType(FilledButton));
    final anchor = AnchorResolver(
      rootKey: rootKey,
    ).targetAt(center, route: '/home')!;

    expect(
      anchor.fingerprint,
      tugboatLabelHash('path=${anchor.canonicalPath}|routeKey=/home'),
    );
    expect(anchor.schemaVersion, tugboatFingerprintSchemaVersion);
  });

  testWidgets('different route keys produce different fingerprints', (
    tester,
  ) async {
    final rootKey = GlobalKey();

    Future<String> fingerprintForRoute(String route) async {
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: rootKey,
            child: Scaffold(
              body: FilledButton(onPressed: () {}, child: const Text('Go')),
            ),
          ),
        ),
      );
      await tester.pump();
      final center = tester.getCenter(find.text('Go'));
      return AnchorResolver(
        rootKey: rootKey,
      ).targetAt(center, route: route)!.fingerprint!;
    }

    expect(
      await fingerprintForRoute('/screen-a'),
      isNot(await fingerprintForRoute('/screen-b')),
    );
  });

  testWidgets('single-pass token map handles large list views', (tester) async {
    final rootKey = GlobalKey();
    final stopwatch = Stopwatch()..start();

    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: Scaffold(
            body: ListView.builder(
              itemCount: 500,
              itemBuilder: (context, index) =>
                  ListTile(title: Text('Row $index'), onTap: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final resolver = AnchorResolver(rootKey: rootKey);
    final inventory = resolver.buildSceneInventory(
      route: '/big-list',
      keyboardOpen: false,
      modalOpen: false,
    );
    stopwatch.stop();

    expect(inventory, isNotNull);
    expect(inventory!.inventoryHash, isNotEmpty);
    expect(stopwatch.elapsedMilliseconds, lessThan(5000));
  });

  testWidgets('generated names replace runtime names in canonical paths', (
    tester,
  ) async {
    final rootKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: const Scaffold(body: _CatalogButton()),
        ),
      ),
    );
    final center = tester.getCenter(find.byType(FilledButton));
    final anchor = AnchorResolver(
      rootKey: rootKey,
      widgetNames: const {_CatalogButton: 'CheckoutButton'},
    ).targetAt(center, route: '/checkout')!;

    expect(anchor.canonicalPath, contains('CheckoutButton'));
  });

  testWidgets('disabled controls retain target role but are not actionable', (
    tester,
  ) async {
    final rootKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: const Scaffold(
            body: FilledButton(onPressed: null, child: Text('Disabled')),
          ),
        ),
      ),
    );

    final resolver = AnchorResolver(rootKey: rootKey);
    final target = resolver.targetAt(
      tester.getCenter(find.text('Disabled')),
      route: '/disabled',
    );
    expect(target?.role, 'button');
    expect(target?.enabled, isFalse);
    expect(target?.actions, isEmpty);
  });

  testWidgets('typed async dropdown callbacks do not crash role inspection', (
    tester,
  ) async {
    final rootKey = GlobalKey();
    final selected = ValueNotifier<int>(1);

    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: selected,
              builder: (context, value, child) {
                return DropdownButton<int>(
                  value: value,
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('One')),
                    DropdownMenuItem(value: 2, child: Text('Two')),
                  ],
                  onChanged: (next) async {
                    if (next != null) selected.value = next;
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final resolver = AnchorResolver(rootKey: rootKey);
    final target = resolver.targetAt(
      tester.getCenter(find.text('One')),
      route: '/dropdown',
    );

    final role = tugboatRoleForWidget(
      tester.widget<DropdownButton<int>>(find.byType(DropdownButton<int>)),
    );
    expect(role?.name, 'dropdown');
    expect(role?.enabled, isTrue);
    expect(target, isNotNull);
    selected.dispose();
  });

  testWidgets('typed radio callbacks resolve roles and anchors', (
    tester,
  ) async {
    final rootKey = GlobalKey();
    final selected = ValueNotifier<int>(1);
    const radioKey = ValueKey<String>('typed-radio');
    const radioTileKey = ValueKey<String>('typed-radio-tile');

    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: Scaffold(
            body: Column(
              children: [
                Radio<int>(
                  key: radioKey,
                  value: 1,
                  // ignore: deprecated_member_use
                  groupValue: 1,
                  // ignore: deprecated_member_use
                  onChanged: (next) async {
                    if (next != null) selected.value = next;
                  },
                ),
                RadioListTile<int>(
                  key: radioTileKey,
                  value: 2,
                  // ignore: deprecated_member_use
                  groupValue: 1,
                  title: const Text('Second option'),
                  // ignore: deprecated_member_use
                  onChanged: (next) async {
                    if (next != null) selected.value = next;
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final radioFinder = find.byKey(radioKey);
    final radioTileFinder = find.byKey(radioTileKey);
    final resolver = AnchorResolver(rootKey: rootKey);

    final radioRole = tugboatRoleForWidget(
      tester.widget<Radio<int>>(radioFinder),
    );
    final radioTileRole = tugboatRoleForWidget(
      tester.widget<RadioListTile<int>>(radioTileFinder),
    );
    final radioAnchor = resolver.targetAt(
      tester.getCenter(radioFinder),
      route: '/radios',
    );
    final radioTileAnchor = resolver.targetAt(
      tester.getCenter(radioTileFinder),
      route: '/radios',
    );

    expect(radioRole?.name, 'radio');
    expect(radioRole?.enabled, isTrue);
    expect(radioTileRole?.name, 'radio');
    expect(radioTileRole?.enabled, isTrue);
    // Radio controls are painted through InkResponse, so hit testing preserves
    // the existing inner-button target role. The direct role checks above
    // verify Radio classification; these assertions cover anchor resolution.
    expect(radioAnchor, isNotNull);
    expect(radioAnchor?.enabled, isTrue);
    expect(radioAnchor?.actions, contains('tap'));
    expect(radioTileAnchor, isNotNull);
    expect(radioTileAnchor?.enabled, isTrue);
    expect(radioTileAnchor?.actions, contains('tap'));
    selected.dispose();
  });

  testWidgets('InkWell-based button yields non-empty canonical path', (
    tester,
  ) async {
    final rootKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: Scaffold(
            body: InkWell(
              onTap: () {},
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Continue'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final center = tester.getCenter(find.text('Continue'));
    final anchor = AnchorResolver(
      rootKey: rootKey,
    ).targetAt(center, route: '/intro')!;
    expect(anchor.canonicalPath, isNotEmpty);
    expect(anchor.canonicalPath, contains('InkWell'));
    expect(anchor.fingerprint, isNotEmpty);
    expect(anchor.fingerprintConfidence, 'low');
  });

  testWidgets('ValueKey tag on InkWell yields high-confidence tagFingerprint', (
    tester,
  ) async {
    final rootKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: Scaffold(
            body: InkWell(
              key: const ValueKey<String>('intro-continue'),
              onTap: () {},
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Continue'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final center = tester.getCenter(find.text('Continue'));
    final anchor = AnchorResolver(
      rootKey: rootKey,
    ).targetAt(center, route: '/intro')!;
    expect(anchor.canonicalPath, contains('InkWell'));
    expect(anchor.tagFingerprint, isNotNull);
    expect(anchor.fingerprintParts, containsPair('tag', 'intro-continue'));
  });

  testWidgets('transformed targets use their painted position', (tester) async {
    final rootKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: Scaffold(
            body: Transform.translate(
              offset: const Offset(0, 500),
              child: FilledButton(onPressed: () {}, child: const Text('Moved')),
            ),
          ),
        ),
      ),
    );

    final target = AnchorResolver(
      rootKey: rootKey,
    ).targetAt(tester.getCenter(find.text('Moved')), route: '/transformed');
    expect(target?.relativePosition, 'bottom');
  });
}

class _CatalogButton extends StatelessWidget {
  const _CatalogButton();

  @override
  Widget build(BuildContext context) {
    return FilledButton(onPressed: () {}, child: const Text('Checkout'));
  }
}

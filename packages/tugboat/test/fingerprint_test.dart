import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';
import 'package:tugboat/src/anchors.dart';

void main() {
  testWidgets('structural positions distinguish dynamic list rows', (
    tester,
  ) async {
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
      return AnchorResolver(rootKey: rootKey).targetAt(center, route: '/feed');
    }

    final row1 = await tapRow(1);
    final row4 = await tapRow(4);
    expect(row1?.fingerprint, isNot(row4?.fingerprint));
    expect(row1?.canonicalPath, contains('[item:1]'));
    expect(row4?.canonicalPath, contains('[item:4]'));
  });

  testWidgets('lazy list tokens use semantic item indices', (tester) async {
    final rootKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: Scaffold(
            body: ListView.builder(
              itemCount: 30,
              itemExtent: 80,
              itemBuilder: (context, index) =>
                  ListTile(title: Text('Row $index'), onTap: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('Row 12'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    final anchor = AnchorResolver(
      rootKey: rootKey,
    ).targetAt(tester.getCenter(find.text('Row 12')), route: '/feed');

    expect(anchor?.canonicalPath, contains('[item:12]'));
  });

  testWidgets('structural positions distinguish short-label list items', (
    tester,
  ) async {
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

  testWidgets('grid fingerprints stay stable across localized text', (
    tester,
  ) async {
    final rootKey = GlobalKey();

    Future<List<TugboatTargetAnchor>> capture(List<String> labels) async {
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: rootKey,
            child: Scaffold(
              body: GridView.count(
                crossAxisCount: 3,
                children: [
                  for (var index = 0; index < labels.length; index++)
                    InkWell(
                      onTap: () {},
                      child: Column(
                        children: [
                          Text(labels[index]),
                          const Expanded(
                            child: Icon(Icons.add_photo_alternate),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final resolver = AnchorResolver(rootKey: rootKey);
      return [
        for (final label in labels)
          resolver.targetAt(
            tester.getCenter(find.text(label)),
            route: '/create',
          )!,
      ];
    }

    final english = await capture(const [
      'Change background',
      'Add text',
      'Upload media',
      'Create shape',
      'Add sticker',
      'Draw freely',
    ]);
    final spanish = await capture(const [
      'Cambiar el fondo',
      'Agregar texto',
      'Subir contenido',
      'Crear forma',
      'Agregar pegatina',
      'Dibujar libremente',
    ]);

    expect(
      english.map((anchor) => anchor.fingerprint).toList(),
      spanish.map((anchor) => anchor.fingerprint).toList(),
    );
    expect(english.map((anchor) => anchor.fingerprint).toSet(), hasLength(6));
    expect(spanish.map((anchor) => anchor.fingerprint).toSet(), hasLength(6));
  });

  testWidgets('grid fingerprints ignore icon changes', (tester) async {
    final rootKey = GlobalKey();

    Future<List<String?>> capture(List<IconData> icons) async {
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: rootKey,
            child: Scaffold(
              body: GridView.count(
                crossAxisCount: 2,
                children: [
                  for (var index = 0; index < icons.length; index++)
                    InkWell(
                      onTap: () {},
                      child: Column(
                        children: [
                          Expanded(child: Icon(icons[index])),
                          Text('Item $index'),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final resolver = AnchorResolver(rootKey: rootKey);
      return [
        for (var index = 0; index < icons.length; index++)
          resolver
              .targetAt(
                tester.getCenter(find.text('Item $index')),
                route: '/tools',
              )
              ?.fingerprint,
      ];
    }

    final first = await capture(const [Icons.image, Icons.text_fields]);
    final second = await capture(const [Icons.photo, Icons.title]);

    expect(first, second);
    expect(first.toSet(), hasLength(2));
  });

  testWidgets('image and text taps resolve to one grid control', (
    tester,
  ) async {
    final rootKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: Scaffold(
            body: GridView.count(
              crossAxisCount: 2,
              children: [
                InkWell(
                  onTap: () {},
                  child: Column(
                    children: [
                      Expanded(
                        child: Image.asset('test/assets/red_square.png'),
                      ),
                      const Text('Change background'),
                    ],
                  ),
                ),
                for (var index = 1; index < 6; index++)
                  InkWell(onTap: () {}, child: Text('Item $index')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final resolver = AnchorResolver(rootKey: rootKey);
    final imageContext = resolver.buildTapContext(
      tapPosition: tester.getCenter(find.byType(Image)),
      route: '/create',
      keyboardOpen: false,
      modalOpen: false,
      detectDismissibleBarrier: false,
    );
    final textContext = resolver.buildTapContext(
      tapPosition: tester.getCenter(find.text('Change background')),
      route: '/create',
      keyboardOpen: false,
      modalOpen: false,
      detectDismissibleBarrier: false,
    );

    expect(
      imageContext.target?.fingerprint,
      textContext.target?.fingerprint,
      reason:
          'image=${imageContext.target?.canonicalPath}; '
          'text=${textContext.target?.canonicalPath}',
    );
    expect(imageContext.target?.fingerprint, isNotEmpty);
    expect(
      imageContext.inventory?.elements.any(
        (entry) => entry.fingerprint == imageContext.target?.fingerprint,
      ),
      isTrue,
    );
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

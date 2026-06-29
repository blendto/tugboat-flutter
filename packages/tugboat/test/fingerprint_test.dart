import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';
import 'package:tugboat/src/anchors.dart'
    show AnchorResolver, tugboatFingerprintSchemaVersion, tugboatLabelHash;

void main() {
  testWidgets('fingerprints are deterministic for the same widget tree', (
    tester,
  ) async {
    final rootKey = GlobalKey();

    Future<TugboatStateAnchor> capture() async {
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: rootKey,
            child: Scaffold(
              body: Column(
                children: [
                  FilledButton(onPressed: () {}, child: const Text('Go')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return AnchorResolver(
        rootKey: rootKey,
      ).buildStateAnchor(route: '/home', keyboardOpen: false, modalOpen: false);
    }

    final first = await capture();
    final second = await capture();
    expect(first.signature, second.signature);
    expect(first.signature, isNotEmpty);
    expect(first.schemaVersion, tugboatFingerprintSchemaVersion);
  });

  testWidgets('list length does not change state signature', (tester) async {
    final rootKey = GlobalKey();

    Future<String> signatureFor(int count) async {
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: rootKey,
            child: Scaffold(
              body: ListView(
                children: [
                  for (var i = 0; i < count; i++)
                    ListTile(title: Text('Row $i'), onTap: () {}),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return AnchorResolver(rootKey: rootKey)
          .buildStateAnchor(
            route: '/feed',
            keyboardOpen: false,
            modalOpen: false,
          )
          .signature;
    }

    expect(await signatureFor(3), await signatureFor(7));
  });

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

  testWidgets('dynamic visible text does not change signatures', (
    tester,
  ) async {
    final rootKey = GlobalKey();

    Future<TugboatStateAnchor> buildAnchor(String label) async {
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: rootKey,
            child: Scaffold(
              body: Column(
                children: [
                  Text(label),
                  FilledButton(onPressed: () {}, child: const Text('Continue')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return AnchorResolver(rootKey: rootKey).buildStateAnchor(
        route: '/intro',
        keyboardOpen: false,
        modalOpen: false,
      );
    }

    final first = await buildAnchor('Brooke Martins');
    final second = await buildAnchor('Alex Chen');
    expect(first.signature, second.signature);
    expect(first.toJson().containsKey('labels'), isFalse);
  });

  testWidgets('TugboatTag adds an alias without changing structural identity', (
    tester,
  ) async {
    final rootKey = GlobalKey();

    Future<(TugboatTargetAnchor, TugboatStateAnchor)> capture({
      required bool tagged,
    }) async {
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
      final resolver = AnchorResolver(rootKey: rootKey);
      final center = tester.getCenter(find.text('Pay now'));
      return (
        resolver.targetAt(center)!,
        resolver.buildStateAnchor(
          route: null,
          keyboardOpen: false,
          modalOpen: false,
        ),
      );
    }

    final untagged = await capture(tagged: false);
    final tagged = await capture(tagged: true);

    expect(tagged.$1.fingerprint, untagged.$1.fingerprint);
    expect(tagged.$1.canonicalPath, untagged.$1.canonicalPath);
    expect(tagged.$2.signature, untagged.$2.signature);
    expect(tagged.$1.tagFingerprint, isNotNull);
    expect(tagged.$1.fingerprintParts, containsPair('tag', 'checkout-cta'));
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

  testWidgets('state signature excludes schema version metadata', (
    tester,
  ) async {
    final rootKey = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: Scaffold(body: const Text('Read only')),
        ),
      ),
    );
    await tester.pump();

    final state = AnchorResolver(
      rootKey: rootKey,
    ).buildStateAnchor(route: '/home', keyboardOpen: false, modalOpen: false);

    expect(state.signature, tugboatLabelHash('actionablePaths=|routeKey=/home'));
    expect(state.schemaVersion, tugboatFingerprintSchemaVersion);
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
    final anchor = resolver.buildStateAnchor(
      route: '/big-list',
      keyboardOpen: false,
      modalOpen: false,
    );
    stopwatch.stop();

    expect(anchor.signature, isNotEmpty);
    expect(stopwatch.elapsedMilliseconds, lessThan(5000));
  });

  testWidgets('same resolver refreshes signatures after an in-route rebuild', (
    tester,
  ) async {
    final rootKey = GlobalKey();
    final contentKey = GlobalKey<_MutableContentState>();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: _MutableContent(key: contentKey),
        ),
      ),
    );
    final resolver = AnchorResolver(rootKey: rootKey);
    final first = resolver.buildStateAnchor(
      route: '/mutable',
      keyboardOpen: false,
      modalOpen: false,
    );

    contentKey.currentState!.showSecondControl();
    await tester.pump();
    final second = resolver.buildStateAnchor(
      route: '/mutable',
      keyboardOpen: false,
      modalOpen: false,
    );

    expect(first.actionableSummary['button'], 1);
    expect(second.actionableSummary['button'], 2);
    expect(second.signature, isNot(first.signature));
  });

  testWidgets('blocking modal excludes controls on the obscured route', (
    tester,
  ) async {
    final rootKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: rootKey,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => AlertDialog(
                    content: const Text('Confirm'),
                    actions: [
                      TextButton(onPressed: () {}, child: const Text('Cancel')),
                      TextButton(onPressed: () {}, child: const Text('Delete')),
                    ],
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    final resolver = AnchorResolver(rootKey: rootKey);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final modal = resolver.buildStateAnchor(
      route: '/home',
      keyboardOpen: false,
      modalOpen: false,
    );
    expect(modal.modalOpen, isTrue);
    expect(modal.actionableSummary['button'], 2);
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

  testWidgets('hidden and off-viewport controls do not affect state identity', (
    tester,
  ) async {
    final rootKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: rootKey,
          child: Scaffold(
            body: Stack(
              children: [
                FilledButton(onPressed: () {}, child: const Text('Visible')),
                Offstage(
                  offstage: true,
                  child: FilledButton(
                    onPressed: () {},
                    child: const Text('Offstage'),
                  ),
                ),
                Opacity(
                  opacity: 0,
                  child: FilledButton(
                    onPressed: () {},
                    child: const Text('Transparent'),
                  ),
                ),
                Positioned(
                  top: 2000,
                  child: FilledButton(
                    onPressed: () {},
                    child: const Text('Outside'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final state = AnchorResolver(rootKey: rootKey).buildStateAnchor(
      route: '/visibility',
      keyboardOpen: false,
      modalOpen: false,
    );
    expect(state.actionableSummary['button'], 1);
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
    final state = resolver.buildStateAnchor(
      route: '/disabled',
      keyboardOpen: false,
      modalOpen: false,
    );
    expect(target?.role, 'button');
    expect(target?.enabled, isFalse);
    expect(target?.actions, isEmpty);
    expect(state.actionableSummary['button'], isNull);
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

class _MutableContent extends StatefulWidget {
  const _MutableContent({super.key});

  @override
  State<_MutableContent> createState() => _MutableContentState();
}

class _MutableContentState extends State<_MutableContent> {
  bool showSecond = false;

  void showSecondControl() => setState(() => showSecond = true);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          FilledButton(onPressed: () {}, child: const Text('First')),
          if (showSecond)
            FilledButton(onPressed: () {}, child: const Text('Second')),
        ],
      ),
    );
  }
}

class _CatalogButton extends StatelessWidget {
  const _CatalogButton();

  @override
  Widget build(BuildContext context) {
    return FilledButton(onPressed: () {}, child: const Text('Checkout'));
  }
}

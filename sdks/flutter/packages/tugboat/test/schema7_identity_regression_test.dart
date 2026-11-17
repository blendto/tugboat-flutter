import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/anchors.dart';
import 'package:tugboat/tugboat.dart';

import 'helpers/widget_capture_wait.dart';

/// Schema 7 must not move a control that none of #137, #139 or #141 is about.
/// Each constant below is the schema 6 tap fingerprint of the same fixture,
/// observed in a worktree at 4f1b72e (the commit before schema 7).
const _schema6Named = <String, String>{
  'back': '79c483d68ef7ea30',
  'action': '7a9abc8a9c0cad85',
  'filled': '4b15c69a4a2b61b2',
  'switchInTile': 'ea83108070379453',
  'switchTile': '9775b37def2dbc5b',
  'checkboxInTile': '2afb749a18bf0af9',
  'checkTile': '137a540cf65f7ef2',
  'textField': '4f357c6ac6912c56',
  'textFormField': 'c4891b58c1e2bdb7',
  'tappedPageView': 'abc86a09f2bfe0c9',
  'inListener': '940d90061a8d4723',
  'inSemantics': '4f2bc6c236a0eab7',
};

const _schema6Anonymous = <String, String>{
  'back': 'eaa5324366eca2cd',
  'action': '9a5e3edf6f74004d',
  'filled': 'b6a1708ec6f41cd1',
  'switchInTile': 'f53fb9dd16586265',
  'switchTile': '40a353b82d73a481',
  'checkboxInTile': '1d2a1d8cc5d29657',
  'checkTile': '72c7c7d8cbba3920',
  'textField': '0696b0c7d70b7381',
  'textFormField': 'bd2657e61af26446',
  'tappedPageView': '906c2f28c5413f59',
  'inListener': '586c7750fdb6ccd7',
  'inSemantics': 'baffff309c8c51f7',
};

const _schema6AnonymousRouteKey = 'struct:144094d666139308';

/// Framework-inserted `IconButtonTheme` (app bar, list tile trailing), a
/// `TextField`'s inner scrollable, a tap detector around a scrollable, and a
/// pointer-up `Listener` or tap `Semantics` around a control: none of them is
/// an app wrapper, an overlay or a disabled control.
Widget _unchangedFixture() => Scaffold(
  appBar: AppBar(
    leading: BackButton(onPressed: () {}),
    actions: [IconButton(onPressed: () {}, icon: const Icon(Icons.search))],
  ),
  body: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      FilledButton(onPressed: () {}, child: const Text('Filled')),
      SwitchListTile(
        value: false,
        onChanged: (_) {},
        title: const Text('Switch tile'),
      ),
      CheckboxListTile(
        value: false,
        onChanged: (_) {},
        title: const Text('Check tile'),
      ),
      const SizedBox(width: 300, child: TextField()),
      SizedBox(width: 300, child: TextFormField()),
      GestureDetector(
        onTap: () {},
        child: SizedBox(
          height: 60,
          width: 300,
          child: PageView(children: const [Text('Page one'), Text('Two')]),
        ),
      ),
      Listener(
        onPointerUp: (_) {},
        child: FilledButton(onPressed: () {}, child: const Text('In listener')),
      ),
      Semantics(
        onTap: () {},
        child: Card(
          child: TextButton(
            onPressed: () {},
            child: const Text('In semantics'),
          ),
        ),
      ),
    ],
  ),
);

final _targets = <String, Finder Function()>{
  'back': () => find.byType(BackButton),
  'action': () => find.byIcon(Icons.search),
  'filled': () => find.text('Filled'),
  'switchInTile': () => find.byType(Switch),
  'switchTile': () => find.text('Switch tile'),
  'checkboxInTile': () => find.byType(Checkbox),
  'checkTile': () => find.text('Check tile'),
  'textField': () => find.byType(TextField).first,
  'textFormField': () => find.byType(TextField).last,
  'tappedPageView': () => find.text('Page one'),
  'inListener': () => find.text('In listener'),
  'inSemantics': () => find.text('In semantics'),
};

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
}

Future<GlobalKey> _mount(WidgetTester tester, Widget home) async {
  _bigView(tester);
  final rootKey = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      home: RepaintBoundary(key: rootKey, child: home),
    ),
  );
  await tester.pumpAndSettle();
  return rootKey;
}

TugboatSceneInventory _inventory(GlobalKey rootKey, String route) =>
    AnchorResolver(rootKey: rootKey).buildSceneInventory(
      route: route,
      keyboardOpen: false,
      modalOpen: false,
      withBoundsEvidence: true,
    )!;

/// The interactive entries whose box contains the centre of [finder].
List<TugboatSceneInventoryEntry> _entriesAt(
  WidgetTester tester,
  TugboatSceneInventory inventory,
  Finder finder,
) {
  final size = tester.view.physicalSize;
  final centre = tester.getCenter(finder);
  final x = centre.dx / size.width;
  final y = centre.dy / size.height;
  return [
    for (final entry in inventory.elements)
      if (entry.tier == 'interactive' &&
          x >= entry.boundsNorm.left &&
          x <= entry.boundsNorm.left + entry.boundsNorm.width &&
          y >= entry.boundsNorm.top &&
          y <= entry.boundsNorm.top + entry.boundsNorm.height)
        entry,
  ];
}

const _exploration = TugboatReplayConfig(
  enabled: true,
  emitSceneInventory: true,
  screenshotMaskLevel: TugboatScreenshotMaskLevel.explicitOnly,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  capturePixelRatio: 1.0,
);

class StackSheet extends StatelessWidget {
  const StackSheet({super.key});
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      FilledButton(onPressed: () {}, child: const Text('Sheet action')),
      TextButton(
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          builder: (_) => const StackSheet(),
        ),
        child: const Text('Again'),
      ),
    ],
  );
}

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

/// Schema 6 content fingerprint of the image below, observed at 4f1b72e.
const _imageSchema6 = '723e1917aaa9d6e8';

Widget _imageUnderTap({required bool tappable}) => Scaffold(
  body: Column(
    children: [
      Semantics(
        onTap: tappable ? () {} : null,
        child: Image.memory(_png, width: 40, height: 40),
      ),
    ],
  ),
);

class FieldSheet extends StatelessWidget {
  const FieldSheet({super.key});
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const SizedBox(width: 300, child: TextField()),
      FilledButton(onPressed: () {}, child: const Text('Act')),
    ],
  );
}

/// Schema 6 fingerprint of the stacked copy's `Sheet action`
/// (`DisplayFeatureSubScreen#1/...` under `ModalBottomSheetRoute<void>`),
/// observed at 4f1b72e.
const _stackedSchema6 = '739b9fdeba690b5c';

void main() {
  tearDown(TugboatReplay.resetForTest);

  testWidgets('controls no schema 7 change is about keep their schema 6 '
      'fingerprints and anonymous route key', (tester) async {
    final rootKey = await _mount(tester, _unchangedFixture());
    for (final (route, expected) in [
      ('/r', _schema6Named),
      ('MaterialPageRoute<dynamic>', _schema6Anonymous),
    ]) {
      final resolver = AnchorResolver(rootKey: rootKey);
      for (final MapEntry(:key, :value) in _targets.entries) {
        final target = resolver.targetAt(
          tester.getCenter(value()),
          route: route,
        );
        expect(target?.fingerprint, expected[key], reason: '$route $key');
      }
    }
    expect(
      _inventory(rootKey, 'MaterialPageRoute<dynamic>').routeKey,
      _schema6AnonymousRouteKey,
    );
  });

  testWidgets('a pointer-up Listener or tap Semantics around a control is '
      'a layer of it, not a second entry', (tester) async {
    final rootKey = await _mount(tester, _unchangedFixture());
    final inventory = _inventory(rootKey, '/r');
    for (final label in ['In listener', 'In semantics']) {
      final entries = _entriesAt(tester, inventory, find.text(label));
      expect(entries, hasLength(1), reason: label);
      expect(entries.single.widgetType, isNot(anyOf('Listener', 'Semantics')));
    }
  });

  testWidgets('a tap Semantics around content keeps the content path', (
    tester,
  ) async {
    for (final tappable in [true, false]) {
      final rootKey = await _mount(tester, _imageUnderTap(tappable: tappable));
      final images = _inventory(
        rootKey,
        '/r',
      ).elements.where((e) => e.widgetType == 'Image');
      expect(images.map((e) => e.fingerprint), [
        _imageSchema6,
      ], reason: 'tappable: $tappable');
    }
  });

  testWidgets('known limit: a widget with no disabled state changes an '
      'anonymous route key when its callback is toggled', (tester) async {
    // A ListTile, InkWell, GestureDetector or tap Semantics without its
    // callback is not a control, so it leaves the struct signature. Flutter
    // gives these no disabled state; see the schema 7 known limits.
    Future<String> key({required bool tappable}) async {
      final rootKey = await _mount(
        tester,
        Scaffold(
          body: Column(
            children: [
              FilledButton(onPressed: () {}, child: const Text('Other')),
              ListTile(
                onTap: tappable ? () {} : null,
                title: const Text('Row'),
              ),
            ],
          ),
        ),
      );
      return _inventory(rootKey, 'MaterialPageRoute<dynamic>').routeKey;
    }

    expect(await key(tappable: true), isNot(await key(tappable: false)));
  });

  testWidgets('a tap Semantics list row keeps its fingerprint when the list '
      'scrolls', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final rootKey = await _mount(
      tester,
      Scaffold(
        body: ListView.builder(
          controller: controller,
          itemCount: 50,
          itemBuilder: (_, i) => Semantics(
            onTap: () {},
            child: SizedBox(height: 40, child: Text('Row $i')),
          ),
        ),
      ),
    );
    String? row20() => AnchorResolver(
      rootKey: rootKey,
    ).targetAt(tester.getCenter(find.text('Row 20')), route: '/r')?.fingerprint;

    final before = row20();
    controller.jumpTo(600);
    await tester.pumpAndSettle();
    expect(before, isNotNull);
    expect(row20(), before);
  });

  testWidgets('a disabled TextField has its enabled twin\'s fingerprint', (
    tester,
  ) async {
    Future<TugboatSceneInventoryEntry> field({required bool enabled}) async {
      final rootKey = await _mount(
        tester,
        Scaffold(
          body: Center(
            child: SizedBox(width: 300, child: TextField(enabled: enabled)),
          ),
        ),
      );
      final entries = _entriesAt(
        tester,
        _inventory(rootKey, '/r'),
        find.byType(TextField),
      );
      expect(entries, hasLength(1));
      return entries.single;
    }

    final enabled = await field(enabled: true);
    final disabled = await field(enabled: false);
    expect(disabled.enabled, isFalse);
    expect(disabled.fingerprint, enabled.fingerprint);
    expect(
      enabled.canonicalPath,
      endsWith('EditableText#0/UndoHistory#0/Scrollable#0'),
    );
  });

  testWidgets('a disabled tile under an open drawer is one entry', (
    tester,
  ) async {
    final scaffold = GlobalKey<ScaffoldState>();
    final rootKey = await _mount(
      tester,
      Scaffold(
        key: scaffold,
        drawer: const Drawer(child: SizedBox.shrink()),
        body: ListTile(enabled: false, onTap: () {}, title: const Text('Off')),
      ),
    );
    final open = _inventory(rootKey, '/r');
    final before = _entriesAt(tester, open, find.text('Off'));
    scaffold.currentState!.openDrawer();
    await tester.pumpAndSettle();
    final covered = _entriesAt(
      tester,
      _inventory(rootKey, '/r'),
      find.text('Off'),
    );
    expect(before, hasLength(1));
    expect(covered.where((e) => e.enabled == false), hasLength(1));
    expect(covered.where((e) => e.role == null), isEmpty);
    expect(
      covered.map((e) => e.fingerprint),
      contains(before.single.fingerprint),
    );
  });

  testWidgets('a wrapped tile before a plain sibling: no alias names another '
      'entry', (tester) async {
    final rootKey = await _mount(
      tester,
      Scaffold(
        body: Column(
          children: [
            ListTileTheme(
              data: const ListTileThemeData(dense: true),
              child: ListTile(onTap: () {}, title: const Text('Wrapped')),
            ),
            ListTile(onTap: () {}, title: const Text('Plain')),
          ],
        ),
      ),
    );
    final entries = _inventory(rootKey, '/r').elements;
    final owner = <String, String>{};
    for (final entry in entries) {
      for (final id in [entry.fingerprint, ...entry.aliases]) {
        final previous = owner[id];
        expect(
          previous == null || previous == entry.fingerprint,
          isTrue,
          reason: '$id names both $previous and ${entry.fingerprint}',
        );
        owner[id] = entry.fingerprint;
      }
    }
  });

  testWidgets('a class sheet keeps its route key while a text selection '
      'toolbar shows', (tester) async {
    _bigView(tester);
    final rootKey = GlobalKey();
    late BuildContext home;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            RepaintBoundary(key: rootKey, child: child!),
        home: Builder(
          builder: (context) {
            home = context;
            return const Scaffold(body: Text('Home'));
          },
        ),
      ),
    );
    showModalBottomSheet<void>(
      context: home,
      builder: (_) => const FieldSheet(),
    );
    await tester.pumpAndSettle();
    const route = 'ModalBottomSheetRoute<void>';
    ({String key, String? act}) observe() {
      final resolver = AnchorResolver(rootKey: rootKey);
      return (
        key: resolver
            .buildSceneInventory(
              route: route,
              keyboardOpen: false,
              modalOpen: true,
              surfaceKind: TugboatSurfaceKind.sheet,
            )!
            .routeKey,
        act: resolver
            .targetAt(tester.getCenter(find.text('Act')), route: route)
            ?.fingerprint,
      );
    }

    final plain = observe();
    await tester.enterText(find.byType(TextField), 'hello world');
    await tester.longPress(find.byType(EditableText));
    await tester.pumpAndSettle();
    expect(find.byType(TextSelectionToolbar), findsOneWidget);
    expect(plain.key, 'sheet:FieldSheet');
    expect(observe(), plain);
  });

  testWidgets('a sheet stacked on its own copy delivers its schema 6 aliases', (
    tester,
  ) async {
    _bigView(tester);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [TugboatReplay.navigatorObserver],
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _exploration, child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (_) => const StackSheet(),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await waitForTugboatCaptureWork(tester);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await waitForTugboatCaptureWork(tester);
    await tester.tap(find.text('Again'));
    await tester.pumpAndSettle();
    await waitForTugboatCaptureWork(tester);

    final aliases = {
      for (final event in TugboatReplay.controller!.session!.events)
        if (event.type == 'scene_inventory')
          for (final entry in event.data['elements']! as List)
            ...((entry as Map)['aliases'] as List? ?? const []),
    };
    expect(aliases, contains(_stackedSchema6));
  });
}

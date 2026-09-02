import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

void main() {
  setUp(TugboatReplay.resetForTest);
  tearDown(TugboatReplay.resetForTest);

  testWidgets(
    'dialog and modal bottom sheet retain canonical route ownership',
    (tester) async {
      final fixture = await _OverlayFixture.mount(tester);

      var eventCursor = fixture.eventCount;
      await tester.tap(find.byKey(_openDialog));
      await tester.pumpAndSettle();
      final dialog = await fixture.route(
        tester,
        '/dialog',
        afterIndex: eventCursor,
      );
      fixture.expectOwned(dialog, '/dialog');

      eventCursor = fixture.eventCount;
      await tester.tap(find.byKey(_closeDialog));
      await tester.pumpAndSettle();
      final dialogPop = await fixture.route(
        tester,
        '/root',
        navigation: 'route_pop',
        afterIndex: eventCursor,
      );
      fixture.expectOwned(dialogPop, '/root');

      eventCursor = fixture.eventCount;
      await tester.tap(find.byKey(_openSheet));
      await tester.pumpAndSettle();
      final sheet = await fixture.route(
        tester,
        '/sheet',
        afterIndex: eventCursor,
      );
      fixture.expectOwned(sheet, '/sheet');

      eventCursor = fixture.eventCount;
      await tester.tap(find.byKey(_closeSheet));
      await tester.pumpAndSettle();
      final sheetPop = await fixture.route(
        tester,
        '/root',
        navigation: 'route_pop',
        afterIndex: eventCursor,
      );
      fixture.expectOwned(sheetPop, '/root');
    },
  );

  testWidgets('nested Navigator transition retains canonical route ownership', (
    tester,
  ) async {
    final fixture = await _OverlayFixture.mount(tester);
    await tester.tap(find.byKey(_openNested));
    await tester.pumpAndSettle();
    final eventCursor = fixture.eventCount;
    await tester.tap(find.byKey(_openNested));
    await tester.pumpAndSettle();

    final change = await fixture.route(
      tester,
      '/nested/details',
      afterIndex: eventCursor,
    );
    fixture.expectOwned(change, '/nested/details');
  });
}

const _openDialog = Key('overlay-open-dialog');
const _closeDialog = Key('overlay-close-dialog');
const _openSheet = Key('overlay-open-sheet');
const _closeSheet = Key('overlay-close-sheet');
const _openNested = Key('overlay-open-nested');

class _OverlayFixture {
  _OverlayFixture(this.controller);

  final TugboatReplayController controller;
  int _frameSerial = 0;

  TugboatSession get session => controller.session!;

  int get eventCount => session.events.length;

  static Future<_OverlayFixture> mount(WidgetTester tester) async {
    final nestedObserver = TugboatNavigatorObserver();
    await tester.pumpWidget(
      MaterialApp(
        initialRoute: '/root',
        navigatorObservers: <NavigatorObserver>[
          TugboatReplay.navigatorObserver,
        ],
        routes: <String, WidgetBuilder>{'/root': (_) => const _RootPage()},
        builder: (context, child) => TugboatReplay.wrapApp(
          config: const TugboatReplayConfig(
            enabled: true,
            emitSceneInventory: true,
            emitViewportSemanticMap: true,
            emitCaptureDiagnostics: true,
            acceptActionContext: true,
            settleDelay: Duration.zero,
            enableGlobalPointerCapture: true,
            capturePixelRatio: 1,
          ),
          child: _NestedObserverScope(observer: nestedObserver, child: child!),
        ),
      ),
    );
    final controller = await _pumpUntil<TugboatReplayController>(
      tester,
      () => TugboatReplay.controller,
      'replay controller',
    );
    final fixture = _OverlayFixture(controller);
    controller.debugExecuteCapture =
        ({required trigger, required force}) async => controller.debugSeedFrame(
          contentHash: 'overlay-${trigger.name}-${fixture._frameSerial++}',
          trigger: trigger,
        );
    await _pumpUntil<TugboatSession>(
      tester,
      () => controller.session,
      'session',
    );
    controller.debugSeedFrame(
      contentHash: 'overlay-initial-${fixture._frameSerial++}',
      trigger: TugboatFrameTrigger.initial,
    );
    return fixture;
  }

  Future<TugboatEvent> route(
    WidgetTester tester,
    String name, {
    String navigation = 'route_push',
    required int afterIndex,
  }) => _pumpUntil<TugboatEvent>(tester, () {
    for (final event in session.events.skip(afterIndex)) {
      if (event.type == 'route_change' &&
          event.data['route'] == name &&
          event.data['navigation'] == navigation) {
        return event;
      }
    }
    return null;
  }, '$navigation $name');

  void expectOwned(TugboatEvent change, String destination) {
    final interactionId = change.data['causeEventId'];
    final interaction = _ofType(
      session,
      'interaction',
    ).singleWhere((event) => event.id == interactionId);
    final frame = change.afterFrame;
    expect(interaction.data['gesture'], 'tap');
    expect(frame, isNotNull);
    expect(change.data['route'], destination);
    expect(change.data['navigationOrigin'], 'interaction');
    expect(change.data['causeEventId'], interaction.id);
    expect(interaction.afterFrame, frame);
    expect(controller.debugFrameProvenance(frame!)!['route'], destination);
  }
}

List<TugboatEvent> _ofType(TugboatSession session, String type) =>
    session.events.where((event) => event.type == type).toList(growable: false);

class _NestedObserverScope extends InheritedWidget {
  const _NestedObserverScope({required this.observer, required super.child});

  final NavigatorObserver observer;

  static NavigatorObserver of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_NestedObserverScope>()!
      .observer;

  @override
  bool updateShouldNotify(_NestedObserverScope oldWidget) =>
      oldWidget.observer != observer;
}

class _RootPage extends StatelessWidget {
  const _RootPage();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: <Widget>[
        FilledButton(
          key: _openDialog,
          onPressed: () => showDialog<void>(
            context: context,
            routeSettings: const RouteSettings(name: '/dialog'),
            builder: (context) => AlertDialog(
              content: FilledButton(
                key: _closeDialog,
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('close dialog'),
              ),
            ),
          ),
          child: const Text('dialog'),
        ),
        FilledButton(
          key: _openSheet,
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            routeSettings: const RouteSettings(name: '/sheet'),
            builder: (context) => SizedBox(
              height: 120,
              child: FilledButton(
                key: _closeSheet,
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('close sheet'),
              ),
            ),
          ),
          child: const Text('sheet'),
        ),
        FilledButton(
          key: _openNested,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              settings: const RouteSettings(name: '/nested-host'),
              builder: (_) => const _NestedHost(),
            ),
          ),
          child: const Text('nested'),
        ),
      ],
    ),
  );
}

class _NestedHost extends StatelessWidget {
  const _NestedHost();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Navigator(
      observers: <NavigatorObserver>[_NestedObserverScope.of(context)],
      onGenerateRoute: (settings) => MaterialPageRoute<void>(
        settings: settings,
        builder: (context) => Center(
          child: FilledButton(
            key: _openNested,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                settings: const RouteSettings(name: '/nested/details'),
                builder: (_) => const SizedBox.shrink(),
              ),
            ),
            child: const Text('nested details'),
          ),
        ),
      ),
    ),
  );
}

Future<T> _pumpUntil<T>(
  WidgetTester tester,
  T? Function() read,
  String description,
) async {
  for (var index = 0; index < 120; index++) {
    final value = read();
    if (value != null) return value;
    await tester.pump(const Duration(milliseconds: 16));
  }
  fail('Timed out waiting for $description');
}

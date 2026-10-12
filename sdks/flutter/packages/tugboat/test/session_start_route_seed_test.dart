import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import 'helpers/widget_capture_wait.dart';

const _testConfig = TugboatReplayConfig(
  enabled: true,
  emitSceneInventory: true,
  emitViewportSemanticMap: true,
  emitCaptureDiagnostics: true,
  acceptActionContext: true,
  settleDelay: Duration.zero,
  interactionClaimWindow: Duration.zero,
  enableGlobalPointerCapture: false,
  capturePixelRatio: 1.0,
);

void main() {
  setUp(() {
    TugboatReplay.debugConfigureControllerForTest = (controller) {
      controller.debugExecuteCapture =
          ({required trigger, required force}) async =>
              controller.debugSeedFrame(trigger: trigger);
    };
  });

  tearDown(TugboatReplay.resetForTest);

  testWidgets('session start seeds initial named route and one session_start', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        initialRoute: '/home',
        navigatorObservers: [TugboatReplay.navigatorObserver],
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        routes: {
          '/home': (_) => Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).pushNamed('/next'),
                child: const Text('Go'),
              ),
            ),
          ),
          '/next': (_) => const Scaffold(body: Text('Next')),
        },
      ),
    );
    await waitForTugboatCaptureWork(tester);

    final controller = TugboatReplay.controller!;
    expect(controller.currentRoute, '/home');

    final sessionStartRoutes = controller.session!.events
        .where(
          (event) =>
              event.type == 'route_change' &&
              event.data['navigation'] == tugboatNavigationSessionStart,
        )
        .toList();
    expect(sessionStartRoutes, hasLength(1));
    expect(sessionStartRoutes.single.data['route'], '/home');
    expect(sessionStartRoutes.single.data.containsKey('fromRoute'), isFalse);

    expect(controller.session!.frames, isNotEmpty);
    final initialFrame = controller.session!.frames.first;
    expect(controller.debugFrameProvenance(initialFrame.id)?['route'], '/home');
    final initialDiagnostic = controller.session!.events
        .where(
          (event) =>
              event.type == 'capture_diagnostic' &&
              event.data['trigger'] == 'initial',
        )
        .first;
    expect(initialDiagnostic.data['outcome'], isNot('superseded_route_epoch'));

    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    await waitForTugboatCaptureWork(tester);

    final pushChange = controller.session!.events
        .where(
          (event) =>
              event.type == 'route_change' &&
              event.data['navigation'] == 'route_push',
        )
        .last;
    expect(pushChange.data['fromRoute'], '/home');
    expect(pushChange.data['route'], '/next');
  });

  testWidgets('session replacement re-seeds the visible route', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        initialRoute: '/home',
        navigatorObservers: [TugboatReplay.navigatorObserver],
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        routes: {'/home': (_) => const Scaffold(body: Text('Home'))},
      ),
    );
    await waitForTugboatCaptureWork(tester);

    final controller = TugboatReplay.controller!;
    controller.clear();
    await waitForTugboatCaptureWork(tester);

    final sessionStartRoutes = controller.session!.events
        .where(
          (event) =>
              event.type == 'route_change' &&
              event.data['navigation'] == tugboatNavigationSessionStart,
        )
        .toList();
    expect(sessionStartRoutes, hasLength(1));
    expect(controller.currentRoute, '/home');
  });

  testWidgets('nested observer seeds deepest navigator route', (tester) async {
    final nestedObserver = TugboatNavigatorObserver();
    await tester.pumpWidget(
      MaterialApp(
        initialRoute: '/root',
        navigatorObservers: [TugboatReplay.navigatorObserver],
        builder: (context, child) => TugboatReplay.wrapApp(
          config: _testConfig,
          child: _NestedObserverScope(observer: nestedObserver, child: child!),
        ),
        routes: {'/root': (_) => const _NestedHost()},
      ),
    );
    await waitForTugboatCaptureWork(tester);

    final controller = TugboatReplay.controller!;
    expect(controller.currentRoute, '/nested/child');
    expect(
      controller.session!.events
          .where(
            (event) =>
                event.type == 'route_change' &&
                event.data['navigation'] == tugboatNavigationSessionStart,
          )
          .single
          .data['route'],
      '/nested/child',
    );
  });

  testWidgets('indexed stack siblings seed the on-screen navigator on clear', (
    tester,
  ) async {
    final tabAObserver = TugboatNavigatorObserver();
    final tabBObserver = TugboatNavigatorObserver();
    var selectedIndex = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: TugboatReplay.wrapApp(
          config: _testConfig,
          child: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: Column(
                children: [
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => setState(() => selectedIndex = 0),
                        child: const Text('Show A'),
                      ),
                      TextButton(
                        onPressed: () => setState(() => selectedIndex = 1),
                        child: const Text('Show B'),
                      ),
                    ],
                  ),
                  Expanded(
                    child: IndexedStack(
                      index: selectedIndex,
                      children: [
                        Navigator(
                          initialRoute: '/tab-a',
                          observers: [tabAObserver],
                          onGenerateRoute: (settings) =>
                              MaterialPageRoute<void>(
                                settings: settings,
                                builder: (_) =>
                                    const Scaffold(body: Text('Tab A')),
                              ),
                        ),
                        Navigator(
                          initialRoute: '/tab-b',
                          observers: [tabBObserver],
                          onGenerateRoute: (settings) =>
                              MaterialPageRoute<void>(
                                settings: settings,
                                builder: (_) =>
                                    const Scaffold(body: Text('Tab B')),
                              ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await waitForTugboatCaptureWork(tester);
    expect(TugboatReplay.controller!.currentRoute, '/tab-a');

    await tester.tap(find.text('Show B'));
    await tester.pumpAndSettle();
    await waitForTugboatCaptureWork(tester);

    final controller = TugboatReplay.controller!;
    controller.clear();
    await waitForTugboatCaptureWork(tester);
    expect(controller.currentRoute, '/tab-b');
  });

  testWidgets('session_start on a sheet carries hostPageRoute', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        initialRoute: '/root',
        navigatorObservers: [TugboatReplay.navigatorObserver],
        builder: (context, child) =>
            TugboatReplay.wrapApp(config: _testConfig, child: child!),
        routes: {
          '/root': (_) => Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  builder: (_) => const Scaffold(body: Text('Sheet')),
                ),
                child: const Text('Open sheet'),
              ),
            ),
          ),
        },
      ),
    );
    await waitForTugboatCaptureWork(tester);
    await tester.tap(find.text('Open sheet'));
    await tester.pumpAndSettle();
    await waitForTugboatCaptureWork(tester);

    final controller = TugboatReplay.controller!;
    controller.clear();
    await waitForTugboatCaptureWork(tester);

    final sessionStart = controller.session!.events
        .where(
          (event) =>
              event.type == 'route_change' &&
              event.data['navigation'] == tugboatNavigationSessionStart,
        )
        .single;
    expect(sessionStart.data['route'], contains('ModalBottomSheetRoute'));
    expect(sessionStart.data['hostPageRoute'], '/root');
  });

  test('start without navigator does not emit session_start route_change', () async {
    final boundaryKey = GlobalKey();
    TestWidgetsFlutterBinding.ensureInitialized();
    final controller = TugboatReplayController(
      config: _testConfig,
      boundaryKey: boundaryKey,
    );
    await controller.initialize();
    controller.start(const Size(320, 640), 'test');

    final seeded = controller.session!.events.where(
      (event) =>
          event.type == 'route_change' &&
          event.data['navigation'] == tugboatNavigationSessionStart,
    );
    expect(seeded, isEmpty);
    expect(controller.currentRoute, isNull);
    controller.dispose();
  });
}

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

class _NestedHost extends StatelessWidget {
  const _NestedHost();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Navigator(
      initialRoute: '/nested/child',
      observers: [_NestedObserverScope.of(context)],
      onGenerateRoute: (settings) => MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => const Scaffold(body: Text('Nested child')),
      ),
    ),
  );
}

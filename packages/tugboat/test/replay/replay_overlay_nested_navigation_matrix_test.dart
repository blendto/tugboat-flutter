import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

/// Real-widget navigation coverage for overlay, nested, and non-table route
/// transitions. Screenshot readback is deterministic, but all Navigator and
/// pointer events are delivered through the mounted replay wrapper.
void main() {
  setUp(TugboatReplay.resetForTest);
  tearDown(TugboatReplay.resetForTest);

  testWidgets('dialog and modal bottom sheet retain their own route evidence', (
    tester,
  ) async {
    final fixture = await _OverlayFixture.mount(tester);

    final dialogStart = fixture.session.events.length;
    await tester.tap(find.byKey(_openDialog));
    await tester.pumpAndSettle();
    final dialogPush = await fixture.waitForRoute(
      tester,
      navigation: 'route_push',
      route: '/dialog',
      after: dialogStart,
    );
    fixture.assertNavigationEvidence(
      routeChange: dialogPush,
      destination: '/dialog',
      after: dialogStart,
    );

    final dialogPopStart = fixture.session.events.length;
    await tester.tap(find.byKey(_closeDialog));
    await tester.pumpAndSettle();
    final dialogPop = await fixture.waitForRoute(
      tester,
      navigation: 'route_pop',
      route: '/root',
      after: dialogPopStart,
    );
    fixture.assertNavigationEvidence(
      routeChange: dialogPop,
      destination: '/root',
      after: dialogPopStart,
    );

    final sheetStart = fixture.session.events.length;
    await tester.tap(find.byKey(_openSheet));
    await tester.pumpAndSettle();
    final sheetPush = await fixture.waitForRoute(
      tester,
      navigation: 'route_push',
      route: '/sheet',
      after: sheetStart,
    );
    fixture.assertNavigationEvidence(
      routeChange: sheetPush,
      destination: '/sheet',
      after: sheetStart,
    );

    final sheetPopStart = fixture.session.events.length;
    await tester.tap(find.byKey(_closeSheet));
    await tester.pumpAndSettle();
    final sheetPop = await fixture.waitForRoute(
      tester,
      navigation: 'route_pop',
      route: '/root',
      after: sheetPopStart,
    );
    fixture.assertNavigationEvidence(
      routeChange: sheetPop,
      destination: '/root',
      after: sheetPopStart,
    );
  });

  testWidgets('nested Navigator transition has destination-local evidence', (
    tester,
  ) async {
    final fixture = await _OverlayFixture.mount(tester);
    final start = fixture.session.events.length;

    await tester.tap(find.byKey(_openNested));
    await tester.pumpAndSettle();
    final nestedStart = fixture.session.events.length;
    expect(
      nestedStart,
      greaterThan(start),
      reason: 'opening the nested host must produce replay activity',
    );
    await tester.tap(find.byKey(_openNested));
    await tester.pumpAndSettle();
    final push = await fixture.waitForRoute(
      tester,
      navigation: 'route_push',
      route: '/nested/details',
      after: nestedStart,
    );

    fixture.assertNavigationEvidence(
      routeChange: push,
      destination: '/nested/details',
      after: nestedStart,
    );
  });

  testWidgets('anonymous and generated routes are classified and linked', (
    tester,
  ) async {
    final fixture = await _OverlayFixture.mount(tester);

    final anonymousStart = fixture.session.events.length;
    await tester.tap(find.byKey(_openAnonymous));
    await tester.pumpAndSettle();
    final anonymous = await fixture.waitForNextRoute(
      tester,
      navigation: 'route_push',
      after: anonymousStart,
    );
    final anonymousRoute = anonymous.data['route'] as String;
    expect(anonymousRoute, contains('MaterialPageRoute'));
    fixture.assertNavigationEvidence(
      routeChange: anonymous,
      destination: anonymousRoute,
      after: anonymousStart,
    );

    final anonymousPopStart = fixture.session.events.length;
    await tester.tap(find.byKey(_popRoute));
    await tester.pumpAndSettle();
    await fixture.waitForRoute(
      tester,
      navigation: 'route_pop',
      route: '/root',
      after: anonymousPopStart,
    );
    final generatedStart = fixture.session.events.length;
    await tester.tap(find.byKey(_openGenerated));
    await tester.pumpAndSettle();
    final generated = await fixture.waitForRoute(
      tester,
      navigation: 'route_push',
      route: '/generated',
      after: generatedStart,
    );
    fixture.assertNavigationEvidence(
      routeChange: generated,
      destination: '/generated',
      after: generatedStart,
    );
  });
}

const _openDialog = Key('overlay-open-dialog');
const _closeDialog = Key('overlay-close-dialog');
const _openSheet = Key('overlay-open-sheet');
const _closeSheet = Key('overlay-close-sheet');
const _openNested = Key('overlay-open-nested');
const _openAnonymous = Key('overlay-open-anonymous');
const _openGenerated = Key('overlay-open-generated');
const _popRoute = Key('overlay-pop-route');

class _OverlayFixture {
  _OverlayFixture(this.controller);

  final TugboatReplayController controller;
  int _frameSerial = 0;

  TugboatSession get session => controller.session!;

  static Future<_OverlayFixture> mount(WidgetTester tester) async {
    final nestedObserver = TugboatNavigatorObserver();
    await tester.pumpWidget(
      MaterialApp(
        initialRoute: '/root',
        navigatorObservers: <NavigatorObserver>[
          TugboatReplay.navigatorObserver,
        ],
        routes: <String, WidgetBuilder>{'/root': (_) => const _RootPage()},
        onGenerateRoute: (settings) {
          if (settings.name == '/generated') {
            return MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => const _RoutePage(label: 'generated'),
            );
          }
          return null;
        },
        builder: (context, child) => TugboatReplay.wrapApp(
          config: const TugboatReplayConfig(
            profile: TugboatCaptureProfile.exploration,
            interactionPublishMode: TugboatInteractionPublishMode.dualWrite,
            settleDelay: Duration.zero,
            interactionClaimWindow: Duration.zero,
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
      description: 'mounted replay controller',
    );
    final fixture = _OverlayFixture(controller);
    controller.debugExecuteCapture =
        ({required trigger, required force}) async {
          return controller.debugSeedFrame(
            contentHash: 'overlay-${trigger.name}-${fixture._frameSerial++}',
            trigger: trigger,
          );
        };
    await _pumpUntil<TugboatSession>(
      tester,
      () => controller.session,
      description: 'active replay session',
    );
    controller.debugSeedFrame(
      contentHash: 'overlay-initial-${fixture._frameSerial++}',
      trigger: TugboatFrameTrigger.initial,
    );
    return fixture;
  }

  Future<TugboatEvent> waitForRoute(
    WidgetTester tester, {
    required String navigation,
    required String route,
    required int after,
  }) => _pumpUntil<TugboatEvent>(tester, () {
    for (final event in session.events.skip(after)) {
      if (event.type == 'route_change' &&
          event.data['navigation'] == navigation &&
          event.data['route'] == route) {
        return event;
      }
    }
    return null;
  }, description: '$navigation $route');

  Future<TugboatEvent> waitForNextRoute(
    WidgetTester tester, {
    required String navigation,
    required int after,
  }) => _pumpUntil<TugboatEvent>(tester, () {
    for (final event in session.events.skip(after)) {
      if (event.type == 'route_change' &&
          event.data['navigation'] == navigation) {
        return event;
      }
    }
    return null;
  }, description: '$navigation route');

  void assertNavigationEvidence({
    required TugboatEvent routeChange,
    required String destination,
    required int after,
  }) {
    final events = session.events;
    final routeIndex = events.indexOf(routeChange);
    final routeFrame = routeChange.afterFrame;
    final requestId = routeChange.data['captureRequestId'];
    final diagnostics = events
        .where(
          (event) =>
              event.type == 'capture_diagnostic' &&
              event.data['requestId'] == requestId,
        )
        .toList(growable: false);
    expect(diagnostics, hasLength(1));
    final diagnostic = diagnostics.single;
    final tap = events
        .sublist(after, routeIndex + 1)
        .lastWhere((event) => event.type == 'tap');
    final linkedSettles = events
        .where(
          (event) =>
              event.type == 'tap_settled' && event.relatedEventId == tap.id,
        )
        .toList(growable: false);
    expect(linkedSettles, hasLength(1));
    final settled = linkedSettles.single;

    expect(routeChange.data['route'], destination);
    expect(requestId, isNotNull);
    expect(routeFrame, isNotNull);
    expect(diagnostic.data['requestId'], requestId);
    expect(diagnostic.data['trigger'], 'route');
    final diagnosticEpoch = diagnostic.data['routeEpoch'];
    expect(diagnosticEpoch, isA<int>());
    expect(settled.relatedEventId, tap.id);
    expect(tap.targetAnchor, isNotNull);
    expect(settled.targetAnchor?.fingerprint, tap.targetAnchor?.fingerprint);
    expect(
      settled.targetAnchor?.canonicalPath,
      tap.targetAnchor?.canonicalPath,
    );
    expect(tap.stateAnchor?.signature, isNotNull);
    expect(routeChange.stateAnchor?.signature, isNotNull);
    expect(settled.stateAnchor?.signature, routeChange.stateAnchor?.signature);
    expect(settled.stateAnchor?.signature, isNot(tap.stateAnchor?.signature));
    expect(settled.afterFrame, routeFrame);
    expect(events.indexOf(tap), lessThan(routeIndex));
    expect(routeIndex, lessThan(events.indexOf(settled)));

    final provenance = controller.debugFrameProvenance(routeFrame!);
    expect(provenance, isNotNull);
    expect(provenance!['route'], destination);
    expect(provenance['routeEpoch'], diagnosticEpoch);
    final beforeProvenance = controller.debugFrameProvenance(tap.beforeFrame!);
    expect(beforeProvenance, isNotNull);
    expect(beforeProvenance!['route'], isNot(destination));
    expect(
      beforeProvenance['routeEpoch'] as int,
      lessThan(diagnosticEpoch as int),
    );
    expect(
      tap.beforeFrame,
      isNot(routeFrame),
      reason: 'a route result must not substitute the origin frame',
    );
    _assertChronological(events);
    expect(controller.debugRouteCapturePending, isFalse);
    expect(controller.debugActiveTapSettleCount, 0);
    expect(controller.debugCaptureInFlight, isFalse);
    expect(controller.debugScheduledCaptureRoutes, isEmpty);
  }
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
        FilledButton(
          key: _openAnonymous,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const _RoutePage(label: 'anonymous'),
            ),
          ),
          child: const Text('anonymous'),
        ),
        FilledButton(
          key: _openGenerated,
          onPressed: () => Navigator.of(context).pushNamed('/generated'),
          child: const Text('generated'),
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
                builder: (_) => const _RoutePage(label: 'nested details'),
              ),
            ),
            child: const Text('nested details'),
          ),
        ),
      ),
    ),
  );
}

class _RoutePage extends StatelessWidget {
  const _RoutePage({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: FilledButton(
        key: _popRoute,
        onPressed: () => Navigator.of(context).pop(),
        child: Text('pop $label'),
      ),
    ),
  );
}

Future<T> _pumpUntil<T>(
  WidgetTester tester,
  T? Function() read, {
  required String description,
}) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    final value = read();
    if (value != null) return value;
    await tester.pump();
  }
  fail('Timed out waiting for $description');
}

void _assertChronological(List<TugboatEvent> events) {
  var previousAt = -1;
  final ids = <String>{};
  for (final event in events) {
    expect(event.atMs, greaterThanOrEqualTo(previousAt));
    expect(ids.add(event.id), isTrue);
    previousAt = event.atMs;
  }
}

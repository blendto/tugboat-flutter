import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

/// Integration coverage for the core Navigator stack operations in #12.
///
/// The widget tree, Navigator observer, pointer listener, and replay root are
/// all real. Capture readback alone is deterministic so the assertions cover
/// causal replay evidence without sleeping for platform image encoding.
void main() {
  setUp(TugboatReplay.resetForTest);
  tearDown(TugboatReplay.resetForTest);

  testWidgets('tap to named push keeps destination evidence coherent', (
    tester,
  ) async {
    final fixture = await _NavigationFixture.mount(tester);
    final baseline = fixture.session.events.length;

    await tester.tap(find.byKey(_rootPushKey));
    await tester.pumpAndSettle();
    final routeChange = await fixture.waitForRouteChange(
      tester,
      navigation: 'route_push',
      destination: '/named',
      after: baseline,
    );

    fixture.assertNavigationTapCoherence(
      routeChange: routeChange,
      expectedRoute: '/named',
      expectedNavigation: 'route_push',
      eventsAfter: baseline,
    );
  });

  testWidgets('tap to replacement does not retain the replaced route frame', (
    tester,
  ) async {
    final fixture = await _NavigationFixture.mount(tester);
    await fixture.openNamed(tester);
    final baseline = fixture.session.events.length;

    await tester.tap(find.byKey(_namedReplaceKey));
    await tester.pumpAndSettle();
    final routeChange = await fixture.waitForRouteChange(
      tester,
      navigation: 'route_replace',
      destination: '/replacement',
      after: baseline,
    );

    fixture.assertNavigationTapCoherence(
      routeChange: routeChange,
      expectedRoute: '/replacement',
      expectedNavigation: 'route_replace',
      eventsAfter: baseline,
    );
    expect(routeChange.data['fromRoute'], '/named');
  });

  testWidgets('tap to pop links to the revealed root route', (tester) async {
    final fixture = await _NavigationFixture.mount(tester);
    await fixture.openNamed(tester);
    final baseline = fixture.session.events.length;

    await tester.tap(find.byKey(_namedPopKey));
    await tester.pumpAndSettle();
    final routeChange = await fixture.waitForRouteChange(
      tester,
      navigation: 'route_pop',
      destination: '/',
      after: baseline,
    );

    fixture.assertNavigationTapCoherence(
      routeChange: routeChange,
      expectedRoute: '/',
      expectedNavigation: 'route_pop',
      eventsAfter: baseline,
    );
    expect(routeChange.data['fromRoute'], '/named');
  });

  testWidgets('pushNamedAndRemoveUntil preserves its new destination capture', (
    tester,
  ) async {
    final fixture = await _NavigationFixture.mount(tester);
    final baseline = fixture.session.events.length;

    await tester.tap(find.byKey(_rootCleanupKey));
    await tester.pumpAndSettle();
    final routeChange = await fixture.waitForRouteChange(
      tester,
      navigation: 'route_push',
      destination: '/cleanup',
      after: baseline,
    );

    fixture.assertNavigationTapCoherence(
      routeChange: routeChange,
      expectedRoute: '/cleanup',
      expectedNavigation: 'route_push',
      eventsAfter: baseline,
    );
    expect(
      fixture.session.events
          .skip(baseline)
          .where((event) => event.type == 'route_change')
          .map((event) => event.data['route']),
      isNot(contains('/')),
      reason: 'removing the old stack must not replace the new destination',
    );
  });
}

const _rootPushKey = Key('root-push-named');
const _rootCleanupKey = Key('root-push-cleanup');
const _namedReplaceKey = Key('named-replace');
const _namedPopKey = Key('named-pop');

class _NavigationFixture {
  _NavigationFixture(this.controller);

  final TugboatReplayController controller;
  int _frameSerial = 0;

  TugboatSession get session => controller.session!;

  static Future<_NavigationFixture> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: <NavigatorObserver>[
          TugboatReplay.navigatorObserver,
        ],
        builder: (context, child) => TugboatReplay.wrapApp(
          config: const TugboatReplayConfig(
            profile: TugboatCaptureProfile.exploration,
            settleDelay: Duration.zero,
            enableGlobalPointerCapture: true,
            capturePixelRatio: 1,
          ),
          child: child!,
        ),
        initialRoute: '/',
        routes: <String, WidgetBuilder>{
          '/': (context) => _RootPage(context: context),
          '/named': (context) => _NamedPage(context: context),
          '/replacement': (context) => const _RoutePage(label: 'replacement'),
          '/cleanup': (context) => const _RoutePage(label: 'cleanup'),
        },
      ),
    );
    final controller = await _pumpUntil<TugboatReplayController>(tester, () {
      return TugboatReplay.controller;
    }, description: 'mounted Tugboat replay controller');
    final fixture = _NavigationFixture(controller);
    controller
        .debugExecuteCapture = ({required trigger, required force}) async {
      // debugSeedFrame records the route epoch/state observed at completion,
      // exactly as a completed capture must do, while avoiding wall-clock IO.
      return controller.debugSeedFrame(
        contentHash: 'matrix-${trigger.name}-${fixture._frameSerial++}',
        trigger: trigger,
      );
    };
    await _pumpUntil<TugboatSession>(tester, () {
      return controller.session;
    }, description: 'active Tugboat replay session');
    // Establish a deterministic predecessor frame before exercising real
    // pointer input. The capture root can start before a test installs its
    // readback seam, so this explicitly models the already-rendered home
    // screen rather than relying on an in-flight platform screenshot.
    controller.debugSeedFrame(
      contentHash: 'matrix-initial-${fixture._frameSerial++}',
      trigger: TugboatFrameTrigger.initial,
    );
    return fixture;
  }

  Future<void> openNamed(WidgetTester tester) async {
    final baseline = session.events.length;
    await tester.tap(find.byKey(_rootPushKey));
    await tester.pumpAndSettle();
    await waitForRouteChange(
      tester,
      navigation: 'route_push',
      destination: '/named',
      after: baseline,
    );
  }

  Future<TugboatEvent> waitForRouteChange(
    WidgetTester tester, {
    required String navigation,
    required String destination,
    required int after,
  }) {
    return _pumpUntil<TugboatEvent>(tester, () {
      final changes = session.events
          .skip(after)
          .where((event) => event.type == 'route_change');
      for (final event in changes) {
        if (event.data['navigation'] == navigation &&
            event.data['route'] == destination) {
          return event;
        }
      }
      return null;
    }, description: '$navigation to $destination');
  }

  void assertNavigationTapCoherence({
    required TugboatEvent routeChange,
    required String expectedRoute,
    required String expectedNavigation,
    required int eventsAfter,
  }) {
    final events = session.events;
    final routeIndex = events.indexOf(routeChange);
    final tap = events
        .sublist(eventsAfter, routeIndex + 1)
        .lastWhere((event) => event.type == 'tap');
    final settle = events
        .skip(routeIndex)
        .firstWhere(
          (event) =>
              event.type == 'tap_settled' && event.relatedEventId == tap.id,
        );
    final routeFrame = routeChange.afterFrame;
    final routeDiagnostic = events.firstWhere(
      (event) =>
          event.type == 'capture_diagnostic' &&
          event.data['requestId'] == routeChange.data['captureRequestId'],
    );

    expect(routeIndex, greaterThan(eventsAfter));
    expect(routeChange.data['route'], expectedRoute);
    expect(routeChange.data['navigation'], expectedNavigation);
    expect(tap.beforeFrame, isNotNull);
    expect(settle.relatedEventId, tap.id);
    expect(settle.afterFrame, routeFrame);
    expect(routeFrame, isNotNull);
    expect(routeDiagnostic.data['outcome'], 'fresh_accepted');
    final diagnosticEpoch = routeDiagnostic.data['routeEpoch'];
    expect(diagnosticEpoch, isA<int>());
    expect(routeDiagnostic.data['trigger'], 'route');

    final provenance = controller.debugFrameProvenance(routeFrame!);
    expect(provenance, isNotNull);
    expect(provenance!['routeEpoch'], diagnosticEpoch);
    expect(provenance['route'], expectedRoute);
    expect(
      events.indexOf(tap),
      lessThan(routeIndex),
      reason: 'input must precede the route it caused',
    );
    expect(routeIndex, lessThan(events.indexOf(settle)));
    _assertChronological(events);
    _assertNoStrandedCaptureWork(controller, session);
  }
}

class _RootPage extends StatelessWidget {
  const _RootPage({required this.context});

  final BuildContext context;

  @override
  Widget build(BuildContext _) {
    return Scaffold(
      body: Column(
        children: <Widget>[
          FilledButton(
            key: _rootPushKey,
            onPressed: () => Navigator.of(context).pushNamed('/named'),
            child: const Text('named'),
          ),
          FilledButton(
            key: _rootCleanupKey,
            onPressed: () => Navigator.of(
              context,
            ).pushNamedAndRemoveUntil('/cleanup', (route) => false),
            child: const Text('cleanup'),
          ),
        ],
      ),
    );
  }
}

class _NamedPage extends StatelessWidget {
  const _NamedPage({required this.context});

  final BuildContext context;

  @override
  Widget build(BuildContext _) {
    return Scaffold(
      body: Column(
        children: <Widget>[
          FilledButton(
            key: _namedReplaceKey,
            onPressed: () =>
                Navigator.of(context).pushReplacementNamed('/replacement'),
            child: const Text('replace'),
          ),
          FilledButton(
            key: _namedPopKey,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('pop'),
          ),
        ],
      ),
    );
  }
}

class _RoutePage extends StatelessWidget {
  const _RoutePage({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Scaffold(body: Text(label));
}

Future<T> _pumpUntil<T>(
  WidgetTester tester,
  T? Function() read, {
  required String description,
}) async {
  for (var i = 0; i < 80; i++) {
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

void _assertNoStrandedCaptureWork(
  TugboatReplayController controller,
  TugboatSession session,
) {
  expect(controller.debugRouteCapturePending, isFalse);
  expect(controller.debugActiveTapSettleCount, 0);
  expect(controller.debugCaptureInFlight, isFalse);
  expect(controller.debugScheduledCaptureRoutes, isEmpty);
  expect(
    session.events.where((event) => event.type == 'session_start'),
    hasLength(1),
  );
}

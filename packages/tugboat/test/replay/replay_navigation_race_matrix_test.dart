import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import '../helpers/replay_coherence_harness.dart';

const _config = TugboatReplayConfig(
  profile: TugboatCaptureProfile.exploration,
  settleDelay: Duration.zero,
  enableGlobalPointerCapture: true,
  capturePixelRatio: 1,
);

List<TugboatEvent> _ofType(TugboatSession session, String type) =>
    session.events.where((event) => event.type == type).toList(growable: false);

List<TugboatEvent> _diagnostics(TugboatSession session) =>
    _ofType(session, 'capture_diagnostic');

Future<void> _nextMicrotask() {
  final completer = Completer<void>();
  scheduleMicrotask(completer.complete);
  return completer.future;
}

({Future<void> done, void Function() cancel}) _scheduleObservedRouteDelay(
  Duration duration,
) {
  final completer = Completer<void>();
  var cancelled = false;
  // Route deadlines are part of the test's controlled transition boundary.
  // Its separate five-second readback barrier remains pending until the route
  // work itself cancels it; collapsing both is an artificial timeout.
  if (duration < const Duration(seconds: 5)) {
    scheduleMicrotask(() {
      if (!cancelled && !completer.isCompleted) completer.complete();
    });
  }
  return (
    done: completer.future,
    cancel: () {
      cancelled = true;
      if (!completer.isCompleted) completer.complete();
    },
  );
}

void _expectEveryDiagnosticRequestIsResolvedOnce(TugboatSession session) {
  final requests = <Object?, int>{};
  for (final event in _diagnostics(session)) {
    final requestId = event.data['requestId'];
    requests[requestId] = (requests[requestId] ?? 0) + 1;
  }
  expect(requests, isNotEmpty);
  expect(requests.values, everyElement(1));
}

Future<TugboatReplayController> _mountObservedApp(
  WidgetTester tester, {
  required GlobalKey<NavigatorState> navigatorKey,
  required Widget home,
  required Map<String, WidgetBuilder> routes,
}) async {
  TugboatReplay.resetForTest();
  var frameIndex = 0;
  TugboatReplay.debugConfigureControllerForTest = (controller) {
    controller.debugDelay = (_) => _nextMicrotask();
    controller.debugScheduleDelay = _scheduleObservedRouteDelay;
    controller.debugExecuteCapture =
        ({required trigger, required force}) async {
          return controller.debugSeedFrame(
            contentHash: 'matrix-${trigger.name}-${frameIndex++}',
            trigger: trigger,
          );
        };
  };
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigatorKey,
      navigatorObservers: <NavigatorObserver>[TugboatReplay.navigatorObserver],
      builder: (context, child) =>
          TugboatReplay.wrapApp(config: _config, child: child!),
      home: home,
      routes: routes,
    ),
  );
  final controller = TugboatReplay.controller!;
  await tester.pump();
  await _drain(tester);
  return controller;
}

Future<void> _drain(WidgetTester tester) async {
  // Pumping frames and microtasks advances only the deterministic test seams;
  // no wall-clock delay is used to make a route/capture race pass.
  for (var index = 0; index < 12; index++) {
    await tester.pump();
  }
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

Future<void> _tearDownObservedApp(WidgetTester tester) async {
  TugboatReplay.resetForTest();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  testWidgets(
    'rapid Navigator successors retain evidence only for visible epoch',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      final controller = await _mountObservedApp(
        tester,
        navigatorKey: navigatorKey,
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              key: const Key('rapid-successors'),
              onPressed: () {
                Navigator.of(context).pushNamed('/a');
                Navigator.of(context).pushNamed('/b');
              },
              child: const Text('Rapid successors'),
            ),
          ),
        ),
        routes: <String, WidgetBuilder>{
          '/a': (_) => const Scaffold(body: Text('A')),
          '/b': (_) => const Scaffold(body: Text('B')),
        },
      );
      addTearDown(() => _tearDownObservedApp(tester));

      await tester.tap(find.byKey(const Key('rapid-successors')));
      await tester.pumpAndSettle();

      final session = controller.session!;
      await _pumpUntil<TugboatEvent>(tester, () {
        for (final event in _ofType(session, 'route_change')) {
          if (event.data['route'] == '/b') return event;
        }
        return null;
      }, description: 'visible /b route capture');
      await _drain(tester);
      final changes = _ofType(session, 'route_change');
      final tap = _ofType(session, 'tap').single;
      final settle = _ofType(session, 'tap_settled').single;
      expect(changes.map((event) => event.data['route']), <String>['/b']);
      expect(settle.relatedEventId, tap.id);
      expect(settle.afterFrame, changes.single.afterFrame);
      expect(
        CoherenceInvariants.hasChronologicalChain(
          events: session.events,
          orderedEventIds: <String>[tap.id, changes.single.id, settle.id],
        ),
        isTrue,
      );
      final routeFrame = changes.single.afterFrame;
      expect(
        routeFrame,
        isNotNull,
        reason:
            'the visible /b route must publish a fresh compatible frame; '
            'route=${changes.single.data}, '
            'diagnostics=${_diagnostics(session).map((event) => event.data).toList()}',
      );
      expect(
        CoherenceInvariants.eventFramesMatchRoute(
          event: changes.single,
          expectedRoute: '/b',
          expectedRouteEpoch: controller.debugRouteEpoch,
          frameProvenanceFor: (candidate) {
            if (candidate == null) return null;
            final data = controller.debugFrameProvenance(candidate);
            final route = data?['route'];
            final epoch = data?['routeEpoch'];
            return route is String && epoch is int
                ? HarnessFrameProvenance(route: route, routeEpoch: epoch)
                : null;
          },
        ),
        isTrue,
      );
      expect(routeFrame, isNotEmpty);
      _expectEveryDiagnosticRequestIsResolvedOnce(session);
      expect(controller.debugRouteCapturePending, isFalse);
      expect(controller.debugActiveTapSettleCount, 0);
      expect(
        controller.debugScheduledCaptureRoutes,
        isEmpty,
        reason:
            'route capture work must drain after the observed swipe/navigation',
      );
    },
  );

  testWidgets('destination tap before route capture degrades explicitly', (
    tester,
  ) async {
    final harness = ReplayCoherenceHarness(
      settleDelay: const Duration(milliseconds: 40),
    );
    await harness.setUpWidgetBacked(tester);
    addTearDown(harness.dispose);

    final route = harness.controller.route(
      'route_push',
      harness.route(
        '/home',
        transitionDuration: const Duration(milliseconds: 150),
      ),
    );
    harness.controller.debugSetCurrentStateAnchor(
      const TugboatStateAnchor(
        signature: 'home',
        signatureParts: <String, String>{'route': '/home'},
      ),
    );
    final position = harness.targetTapPosition(tester);
    harness.controller.recordPointerDown(position);
    harness.controller.recordPointerUp(position);
    final session = harness.controller.session!;
    final tap = _ofType(session, 'tap').single;

    expect(tap.beforeFrame, isNull);
    expect(tap.data['frameAttachment'], <String, Object?>{
      'before': 'unavailable',
      'reason': 'no_compatible_frame',
    });
    await harness.flushScheduler();
    await route;

    final change = _ofType(session, 'route_change').single;
    final settle = _ofType(session, 'tap_settled').single;
    expect(change.data['route'], '/home');
    expect(settle.relatedEventId, tap.id);
    expect(settle.beforeFrame, isNull);
    expect(settle.afterFrame, change.afterFrame);
    expect(
      CoherenceInvariants.hasChronologicalChain(
        events: session.events,
        orderedEventIds: <String>[tap.id, change.id, settle.id],
      ),
      isTrue,
    );
    _expectEveryDiagnosticRequestIsResolvedOnce(session);
    expect(CoherenceInvariants.hasNoStrandedCaptureWork(harness), isTrue);
    await harness.tearDownWidgetBacked(tester);
  });

  test('taps sharing an in-flight screenshot each settle once', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);
    harness.seedRouteState(route: '/home', signature: 'home');
    harness.capturer.blockNext = true;

    harness.controller.recordPointerDown(const Offset(12, 12), pointer: 1);
    harness.controller.recordPointerUp(const Offset(12, 12), pointer: 1);
    await harness.pumpQueueWork();
    expect(harness.capturer.blockedCount, 1);
    harness.controller.recordPointerDown(const Offset(24, 24), pointer: 2);
    harness.controller.recordPointerUp(const Offset(24, 24), pointer: 2);
    await harness.pumpQueueWork();
    harness.capturer.completeBlocked();
    await harness.flushScheduler();

    final session = harness.controller.session!;
    final taps = _ofType(session, 'tap');
    final settles = _ofType(session, 'tap_settled');
    expect(taps, hasLength(2));
    expect(settles, hasLength(2));
    expect(
      settles.map((event) => event.relatedEventId).toSet(),
      taps.map((event) => event.id).toSet(),
    );
    for (final tap in taps) {
      final settle = settles.singleWhere(
        (event) => event.relatedEventId == tap.id,
      );
      expect(
        CoherenceInvariants.tapSettleIsLinked(
          events: session.events,
          tap: tap,
          settle: settle,
        ),
        isTrue,
      );
    }
    _expectEveryDiagnosticRequestIsResolvedOnce(session);
    expect(CoherenceInvariants.hasNoStrandedCaptureWork(harness), isTrue);
  });

  testWidgets('real swipe input overlapping Navigator push stays swipe-only', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final controller = await _mountObservedApp(
      tester,
      navigatorKey: navigatorKey,
      home: Scaffold(
        body: ListView.builder(
          key: const Key('scroll-list'),
          itemCount: 30,
          itemBuilder: (_, index) => ListTile(title: Text('row $index')),
        ),
      ),
      routes: <String, WidgetBuilder>{
        '/details': (_) => const Scaffold(body: Text('Details')),
      },
    );
    addTearDown(() => _tearDownObservedApp(tester));

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('scroll-list'))),
    );
    await gesture.moveBy(const Offset(0, -160));
    navigatorKey.currentState!.pushNamed('/details');
    await gesture.up();
    await tester.pumpAndSettle();
    await _drain(tester);

    final session = controller.session!;
    final tap = _ofType(session, 'tap').single;
    final scrollStart = _ofType(session, 'scroll_start').single;
    final swipe = _ofType(session, 'swipe').single;
    final scrollEnd = _ofType(session, 'scroll_end').single;
    final change = _ofType(session, 'route_change').single;
    expect(_ofType(session, 'tap_settled'), isEmpty);
    expect(swipe.relatedEventId, tap.id);
    expect(swipe.data['scrolled'], isTrue);
    expect(scrollEnd.relatedEventId, scrollStart.id);
    expect(scrollEnd.afterFrame, isNull);
    expect(scrollEnd.data['captureOutcome'], 'superseded_route_epoch');
    expect(scrollEnd.data['frameAttachment'], <String, Object?>{
      'after': 'unavailable',
      'reason': 'superseded_route_epoch',
    });
    expect(change.data['route'], '/details');
    expect(
      CoherenceInvariants.hasChronologicalChain(
        events: session.events,
        orderedEventIds: <String>[
          tap.id,
          scrollStart.id,
          swipe.id,
          scrollEnd.id,
          change.id,
        ],
      ),
      isTrue,
    );
    _expectEveryDiagnosticRequestIsResolvedOnce(session);
    expect(controller.debugRouteCapturePending, isFalse);
    expect(controller.debugActiveTapSettleCount, 0);
    expect(
      controller.debugScheduledCaptureRoutes,
      isEmpty,
      reason: 'route capture work must drain after the observed navigation',
    );
  });
}

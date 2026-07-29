import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import '../helpers/replay_coherence_harness.dart';

/// Programmatic / automatic navigation matrix (U11).
void main() {
  void expectAutomatic(TugboatEvent change) {
    expect(change.data['navigationOrigin'], 'automatic_or_unknown');
    expect(change.data['causeEventId'], isNull);
  }

  test('direct push/replace/pop emit automatic_or_unknown', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    await harness.controller.route('route_push', harness.route('/a'));
    await harness.controller.route('route_replace', harness.route('/b'));
    await harness.controller.route('route_pop', harness.route('/a'));
    await harness.pumpQueueWork();

    final changes = harness.controller.session!.ofType('route_change');
    expect(changes.length, greaterThanOrEqualTo(3));
    for (final change in changes) {
      expectAutomatic(change);
    }
    expect(harness.controller.session!.ofType('tap'), isEmpty);
    expect(CoherenceInvariants.hasNoStrandedCaptureWork(harness), isTrue);
  });

  test('service-style push without pointer stays automatic', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    await harness.controller.route('route_push', harness.route('/login'));
    await harness.controller.route('route_replace', harness.route('/home'));
    await harness.pumpQueueWork();

    final home = harness.controller.session!
        .ofType('route_change')
        .where((e) => e.data['route'] == '/home')
        .last;
    expectAutomatic(home);
    expect(home.afterFrame, isNotNull);
    expect(harness.controller.session!.ofType('tap'), isEmpty);
  });

  test('auth redirect after settle does not claim prior tap', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.controller.recordPointerDown(const Offset(8, 8));
    harness.controller.recordPointerUp(const Offset(8, 8));
    await harness.pumpQueueWork();

    await harness.controller.route('route_push', harness.route('/login'));
    await harness.controller.route('route_replace', harness.route('/home'));
    await harness.pumpQueueWork();

    final home = harness.controller.session!
        .ofType('route_change')
        .where((e) => e.data['route'] == '/home')
        .last;
    expectAutomatic(home);
  });

  test(
    'automatic navigation overlapping tap settle stays independent',
    () async {
      final harness = ReplayCoherenceHarness(
        settleDelay: const Duration(milliseconds: 100),
      );
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.seedRouteState(route: '/source', signature: 'source');
      harness.controller.recordPointerDown(const Offset(8, 8));
      harness.controller.recordPointerUp(const Offset(8, 8));
      final tap = harness.controller.session!.ofType('tap').single;

      await harness.pumpMicrotasks();

      // The pointer event turn has ended, so this navigation must remain
      // automatic even though the tap's settle delay is still active.
      final automaticRoute = harness.controller.route(
        'route_push',
        harness.route('/redirect'),
      );
      harness.scheduler.advance(const Duration(milliseconds: 100));
      await harness.pumpQueueWork();
      await automaticRoute;
      await harness.flushScheduler();

      final redirect = harness.controller.session!
          .ofType('route_change')
          .lastWhere((event) => event.data['route'] == '/redirect');
      final settled = harness.controller.session!
          .ofType('tap_settled')
          .singleWhere((event) => event.relatedEventId == tap.id);
      final observation = Map<String, Object?>.from(
        settled.data['settleObservation']! as Map,
      );

      expectAutomatic(redirect);
      expect(observation['navigationOutcome'], 'same_route');
      expect(observation['routeEventId'], isNull);
      expect(
        observation['captureRequestId'],
        isNot(redirect.data['captureRequestId']),
      );
    },
  );

  test(
    'automatic successor cannot replace a tap-caused route barrier',
    () async {
      final harness = ReplayCoherenceHarness(
        settleDelay: const Duration(milliseconds: 100),
      );
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(8, 8));
      final tappedRoute = harness.controller.route(
        'route_push',
        harness.route('/tapped'),
      );
      harness.controller.recordPointerUp(const Offset(8, 8));
      final tap = harness.controller.session!.ofType('tap').single;

      // Supersede the causally claimed route before its terminal frame is
      // available. The redirect has no pointer cause and must not become the
      // tap's route barrier through successor transfer.
      final automaticRoute = harness.controller.route(
        'route_replace',
        harness.route('/redirect'),
      );
      await harness.pumpMicrotasks();
      harness.scheduler.advance(const Duration(milliseconds: 100));
      await harness.pumpQueueWork();
      await Future.wait([tappedRoute, automaticRoute]);
      await harness.flushScheduler();

      final redirect = harness.controller.session!
          .ofType('route_change')
          .lastWhere((event) => event.data['route'] == '/redirect');
      final settled = harness.controller.session!
          .ofType('tap_settled')
          .singleWhere((event) => event.relatedEventId == tap.id);
      final observation = Map<String, Object?>.from(
        settled.data['settleObservation']! as Map,
      );

      expectAutomatic(redirect);
      expect(observation['navigationOutcome'], 'navigation_unavailable');
      expect(observation['routeEventId'], isNull);
      expect(settled.afterFrame, isNull);
    },
  );

  test('verified tap then automatic redirect keep distinct origins', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.controller.recordPointerDown(const Offset(3, 3));
    final tappedRoute = harness.controller.route(
      'route_push',
      harness.route('/tapped'),
    );
    harness.controller.recordPointerUp(const Offset(3, 3));
    final tap = harness.controller.session!.ofType('tap').single;
    await tappedRoute;
    await harness.pumpQueueWork();

    await harness.controller.route('route_push', harness.route('/redirect'));
    await harness.pumpQueueWork();

    final tapped = harness.controller.session!
        .ofType('route_change')
        .where((e) => e.data['route'] == '/tapped')
        .last;
    final redirect = harness.controller.session!
        .ofType('route_change')
        .where((e) => e.data['route'] == '/redirect')
        .last;

    expect(tapped.data['navigationOrigin'], 'interaction');
    expect(tapped.data['causeEventId'], tap.id);
    expectAutomatic(redirect);
  });

  test(
    'stack cleanup remove stays automatic without fabricated taps',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      await harness.controller.route('route_push', harness.route('/'));
      await harness.controller.route('route_push', harness.route('/intro'));
      await harness.controller.route('route_push', harness.route('/cleanup'));
      await harness.controller.route('route_remove', harness.route('/intro'));
      await harness.pumpQueueWork();

      for (final change in harness.controller.session!.ofType('route_change')) {
        expectAutomatic(change);
      }
      expect(harness.controller.session!.ofType('tap'), isEmpty);
      expect(CoherenceInvariants.hasNoStrandedCaptureWork(harness), isTrue);
    },
  );
}

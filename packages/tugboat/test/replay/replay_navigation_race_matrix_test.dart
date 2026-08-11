import 'package:flutter_test/flutter_test.dart';

import '../helpers/replay_coherence_harness.dart';

void main() {
  test(
    'route capture supersession publishes only the replacement evidence',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.capturer.blockNext = true;
      final stale = harness.controller.route(
        'route_push',
        harness.route('/stale'),
      );
      await harness.pumpQueueWork();
      expect(harness.capturer.blockedCount, 1);

      final replacement = harness.controller.route(
        'route_push',
        harness.route('/replacement'),
      );
      await stale;
      harness.capturer.completeBlocked('stale-frame');
      await harness.flushScheduler();
      await replacement;

      final changes = harness.controller.session!.ofType('route_change');
      expect(changes.map((event) => event.data['route']), ['/replacement']);
      expect(changes.single.afterFrame, isNotNull);
      expect(harness.controller.debugRouteCapturePending, isFalse);
    },
  );

  test('timed-out route capture has no borrowed interaction frame', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    final before = harness.seedRouteState(
      route: '/origin',
      signature: 'origin',
    );
    harness.controller.recordPointerDown(const Offset(10, 10));
    harness.capturer.blockNext = true;
    final route = harness.controller.route(
      'route_push',
      harness.route('/blocked'),
    );
    harness.controller.recordPointerUp(const Offset(10, 10));
    await harness.pumpQueueWork();
    await harness.tick(const Duration(seconds: 5));
    await route;

    final session = harness.controller.session!;
    final interaction = session.ofType('interaction').single;
    final change = session.ofType('route_change').single;
    expect(interaction.data['gesture'], 'tap');
    expect(interaction.beforeFrame, before);
    expect(interaction.afterFrame, isNull);
    expect(change.data['causeEventId'], interaction.id);
    expect(change.afterFrame, isNull);
    expect(change.data['captureOutcome'], 'timed_out');

    harness.capturer.completeBlocked('late-route-frame');
    await harness.pumpQueueWork();
    expect(harness.controller.latestFrameId, before);
  });

  test('failed route capture has no borrowed interaction frame', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    final before = harness.seedRouteState(
      route: '/origin',
      signature: 'origin',
    );
    harness.controller.recordPointerDown(const Offset(10, 10));
    harness.capturer.failNext = true;
    final route = harness.controller.route(
      'route_push',
      harness.route('/failed'),
    );
    harness.controller.recordPointerUp(const Offset(10, 10));
    await harness.flushScheduler();
    await route;

    final session = harness.controller.session!;
    final interaction = session.ofType('interaction').single;
    final change = session.ofType('route_change').single;
    expect(interaction.data['gesture'], 'tap');
    expect(interaction.beforeFrame, before);
    expect(interaction.afterFrame, isNull);
    expect(change.data['causeEventId'], interaction.id);
    expect(change.afterFrame, isNull);
    expect(change.data['captureOutcome'], 'failed');
  });

  test('ambiguous multi-pointer gestures cannot claim a route', () async {
    final harness = ReplayCoherenceHarness(
      interactionClaimWindow: const Duration(milliseconds: 1250),
    );
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.controller.recordPointerDown(const Offset(10, 10), pointer: 1);
    harness.controller.recordPointerDown(const Offset(20, 20), pointer: 2);
    harness.controller.recordPointerUp(const Offset(10, 10), pointer: 1);
    harness.controller.recordPointerUp(const Offset(20, 20), pointer: 2);
    final route = harness.controller.route(
      'route_push',
      harness.route('/automatic'),
    );
    await harness.flushScheduler();
    await route;

    final interactions = harness.controller.session!.ofType('interaction');
    final change = harness.controller.session!.ofType('route_change').single;
    expect(interactions, hasLength(2));
    expect(
      interactions.every((event) => event.data['gesture'] == 'tap'),
      isTrue,
    );
    expect(change.data['causeEventId'], isNull);
    expect(change.data['navigationOrigin'], 'automatic_or_unknown');
  });
}

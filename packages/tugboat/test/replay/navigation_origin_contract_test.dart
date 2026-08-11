import 'package:flutter_test/flutter_test.dart';

import '../helpers/replay_coherence_harness.dart';

void main() {
  test('same-turn route has a canonical interaction cause', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);
    harness.seedRouteState(route: '/home', signature: 'home');
    harness.controller.recordPointerDown(const Offset(10, 10));
    final route = harness.controller.route(
      'route_push',
      harness.route('/next'),
    );
    harness.controller.recordPointerUp(const Offset(10, 10));
    await harness.flushScheduler();
    await route;
    final session = harness.controller.session!;
    expect(
      session.ofType('route_change').single.data['causeEventId'],
      session.ofType('interaction').single.id,
    );
  });

  test('automatic route has no interaction cause', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);
    final route = harness.controller.route(
      'route_push',
      harness.route('/next'),
    );
    await harness.flushScheduler();
    await route;
    expect(
      harness.controller.session!.ofType('route_change').single.data,
      isNot(contains('causeEventId')),
    );
  });
}

import 'package:flutter_test/flutter_test.dart';

import '../helpers/replay_coherence_harness.dart';

void main() {
  test('route event can precede its terminal canonical interaction', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);
    harness.controller.recordPointerDown(const Offset(12, 12));
    final route = harness.controller.route(
      'route_push',
      harness.route('/next'),
    );
    harness.controller.recordPointerUp(const Offset(12, 12));
    await harness.flushScheduler();
    await route;
    final session = harness.controller.session!;
    final interaction = session.ofType('interaction').single;
    expect(
      session.ofType('route_change').single.data['causeEventId'],
      interaction.id,
    );
  });
}

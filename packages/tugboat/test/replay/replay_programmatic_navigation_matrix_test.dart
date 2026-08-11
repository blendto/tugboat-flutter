import 'package:flutter_test/flutter_test.dart';

import '../helpers/replay_coherence_harness.dart';

void main() {
  test(
    'programmatic navigation emits route evidence without an interaction',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);
      final route = harness.controller.route(
        'route_push',
        harness.route('/next'),
      );
      await harness.flushScheduler();
      await route;
      final session = harness.controller.session!;
      expect(session.ofType('interaction'), isEmpty);
      expect(
        session.ofType('route_change').single.data,
        isNot(contains('causeEventId')),
      );
    },
  );

  test(
    'automatic redirect after a completed interaction keeps no route cause',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(8, 8));
      harness.controller.recordPointerUp(const Offset(8, 8));
      await harness.flushScheduler();
      final interaction = harness.controller.session!
          .ofType('interaction')
          .single;

      await harness.controller.route('route_push', harness.route('/login'));
      await harness.controller.route('route_replace', harness.route('/home'));
      await harness.flushScheduler();

      final changes = harness.controller.session!.ofType('route_change');
      final home = changes.lastWhere((event) => event.data['route'] == '/home');
      expect(interaction.data['gesture'], 'tap');
      expect(home.data['navigationOrigin'], 'automatic_or_unknown');
      expect(home.data['causeEventId'], isNull);
      expect(home.afterFrame, isNotNull);
    },
  );

  for (final navigation in [
    'route_push',
    'route_replace',
    'route_pop',
    'route_remove',
  ]) {
    test('$navigation owns destination route evidence', () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);
      final route = harness.controller.route(
        navigation,
        harness.route('/$navigation'),
      );
      await harness.flushScheduler();
      await route;
      final change = harness.controller.session!.ofType('route_change').single;
      expect(change.data['navigation'], navigation);
      expect(change.data['route'], '/$navigation');
      expect(change.afterFrame, isNotNull);
    });
  }
}

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

  test('verified tap then automatic redirect keep distinct origins', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.controller.recordPointerDown(const Offset(3, 3));
    final tap = harness.controller.session!.ofType('tap').single;
    await harness.controller.route('route_push', harness.route('/tapped'));
    harness.controller.recordPointerUp(const Offset(3, 3));
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

  test('stack cleanup remove stays automatic without fabricated taps', () async {
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
  });
}

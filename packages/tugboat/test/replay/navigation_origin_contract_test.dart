import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import '../helpers/replay_coherence_harness.dart';

Map<String, Object?> _roundTrip(Map<String, Object?> json) =>
    Map<String, Object?>.from(jsonDecode(jsonEncode(json)) as Map);

/// Navigation-origin and causal-link contract (U10).
void main() {
  test('route_change serializes automatic_or_unknown without a cause', () {
    final event = TugboatEvent(
      id: 'event-1',
      atMs: 10,
      type: 'route_change',
      data: const {
        'route': '/dest',
        'navigation': 'route_push',
        'navigationOrigin': 'automatic_or_unknown',
      },
    );
    final json = _roundTrip(event.toJson());
    final data = Map<String, Object?>.from(json['data']! as Map);
    expect(data['navigationOrigin'], 'automatic_or_unknown');
    expect(data.containsKey('causeEventId'), isFalse);
  });

  test('legacy route_change without origin remains readable as unknown', () {
    final event = TugboatEvent(
      id: 'event-legacy',
      atMs: 1,
      type: 'route_change',
      data: const {'route': '/a', 'navigation': 'route_push'},
    );
    final json = _roundTrip(event.toJson());
    final data = Map<String, Object?>.from(json['data']! as Map);
    expect(data['navigationOrigin'], isNull);
    final origin =
        data['navigationOrigin'] as String? ?? 'automatic_or_unknown';
    expect(origin, 'automatic_or_unknown');
  });

  test('interaction-caused route preserves the original tap id', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.controller.recordPointerDown(const Offset(12, 34));
    final tap = harness.controller.session!.ofType('tap').single;

    await harness.controller.route('route_push', harness.route('/dest'));
    await harness.flushScheduler();

    final change = harness.controller.session!
        .ofType('route_change')
        .lastWhere((e) => e.data['route'] == '/dest');
    expect(change.data['navigationOrigin'], 'interaction');
    expect(change.data['causeEventId'], tap.id);
  });

  test('timer redirect after tap settle has no causal event id', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.controller.recordPointerDown(const Offset(12, 34));
    harness.controller.recordPointerUp(const Offset(12, 34));
    await harness.flushScheduler();

    await harness.controller.route('route_push', harness.route('/redirect'));
    await harness.flushScheduler();

    final change = harness.controller.session!
        .ofType('route_change')
        .lastWhere((e) => e.data['route'] == '/redirect');
    expect(change.data['navigationOrigin'], 'automatic_or_unknown');
    expect(change.data['causeEventId'], isNull);
  });

  test('cancelled pointer cannot claim a route', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.controller.recordPointerDown(const Offset(12, 34));
    harness.controller.recordPointerCancel(const Offset(12, 34));
    await harness.controller.route('route_push', harness.route('/x'));
    await harness.flushScheduler();

    final change = harness.controller.session!.ofType('route_change').last;
    expect(change.data['navigationOrigin'], 'automatic_or_unknown');
    expect(change.data['causeEventId'], isNull);
  });

  test('swipe classification cannot claim a route', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.controller.recordPointerDown(const Offset(12, 80));
    harness.controller.markPendingTapAsSwipe(0);
    await harness.controller.route('route_push', harness.route('/swipe'));
    await harness.flushScheduler();

    final change = harness.controller.session!.ofType('route_change').last;
    expect(change.data['navigationOrigin'], 'automatic_or_unknown');
    expect(change.data['causeEventId'], isNull);
  });

  test('ambiguous multi-touch cannot claim a route', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.controller.recordPointerDown(const Offset(10, 10), pointer: 1);
    harness.controller.recordPointerDown(const Offset(20, 20), pointer: 2);
    await harness.controller.route('route_push', harness.route('/multi'));
    await harness.flushScheduler();

    final change = harness.controller.session!.ofType('route_change').last;
    expect(change.data['navigationOrigin'], 'automatic_or_unknown');
    expect(change.data['causeEventId'], isNull);
  });

  test('superseded successor does not inherit the verified cause', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.controller.recordPointerDown(const Offset(12, 34));
    final tap = harness.controller.session!.ofType('tap').single;

    await harness.controller.route('route_push', harness.route('/first'));
    await harness.pumpMicrotasks();

    // Second navigation has no eligible unclaimed tap — cause was consumed.
    await harness.controller.route('route_push', harness.route('/second'));
    await harness.pumpQueueWork();

    final changes = harness.controller.session!.ofType('route_change');
    final first = changes.where((e) => e.data['route'] == '/first').toList();
    final second = changes.where((e) => e.data['route'] == '/second').toList();

    expect(first, isNotEmpty);
    expect(first.first.data['navigationOrigin'], 'interaction');
    expect(first.first.data['causeEventId'], tap.id);

    expect(second, isNotEmpty);
    expect(second.last.data['navigationOrigin'], 'automatic_or_unknown');
    expect(second.last.data['causeEventId'], isNull);
  });
}

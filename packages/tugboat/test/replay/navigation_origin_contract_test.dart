import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
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
    expect(harness.controller.session!.ofType('tap'), isEmpty);

    await harness.controller.route('route_push', harness.route('/dest'));
    await harness.flushScheduler();

    final tap = harness.controller.session!.ofType('tap').single;
    final change = harness.controller.session!
        .ofType('route_change')
        .lastWhere((e) => e.data['route'] == '/dest');
    expect(change.data['navigationOrigin'], 'interaction');
    expect(change.data['causeEventId'], tap.id);
    expect(change.data['interactionAttribution'], 'same_turn');
  });

  test(
    'same-turn claim attributes navigation during pointer-up turn',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(12, 34));
      harness.controller.recordPointerUp(const Offset(12, 34));
      // Still in the pointer-up turn — sync onTap → Navigator can claim.
      await harness.controller.route('route_push', harness.route('/async'));
      await harness.flushScheduler();

      final tap = harness.controller.session!.ofType('tap').single;
      final change = harness.controller.session!
          .ofType('route_change')
          .lastWhere((e) => e.data['route'] == '/async');
      expect(change.data['navigationOrigin'], 'interaction');
      expect(change.data['causeEventId'], tap.id);
      expect(change.data['interactionAttribution'], 'same_turn');
    },
  );

  test('timer redirect after pointer-up turn has no causal event id', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.controller.recordPointerDown(const Offset(12, 34));
    harness.controller.recordPointerUp(const Offset(12, 34));
    // Expire the released same-turn claim.
    await harness.pumpMicrotasks();

    await harness.controller.route('route_push', harness.route('/redirect'));
    await harness.flushScheduler();

    final change = harness.controller.session!
        .ofType('route_change')
        .lastWhere((e) => e.data['route'] == '/redirect');
    expect(change.data['navigationOrigin'], 'automatic_or_unknown');
    expect(change.data['causeEventId'], isNull);
  });

  test('pre-up claimed route then swipe keeps tap causal_only', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.controller.recordPointerDown(const Offset(12, 80));
    await harness.controller.route('route_push', harness.route('/claimed'));
    await harness.flushScheduler();
    expect(harness.controller.session!.ofType('tap'), isNotEmpty);

    harness.controller.markPendingTapAsSwipe(0);
    harness.controller.recordPointerUp(const Offset(40, 80));
    await harness.flushScheduler();

    final tap = harness.controller.session!.ofType('tap').single;
    expect(tap.data['replayRole'], 'causal_only');
    expect(tap.data['gestureFinal'], anyOf('swipe', 'unresolved'));
    final swipe = harness.controller.session!.ofType('swipe').single;
    expect(swipe.data['invalidatesRelatedTap'], isTrue);
  });

  test('pointer events after session_end are ignored', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.controller.recordPointerDown(const Offset(12, 34));
    await harness.controller.endSession();
    final before = harness.controller.session!.events.length;

    harness.controller.recordPointerUp(const Offset(12, 34));
    harness.controller.recordPointerDown(const Offset(50, 50));
    harness.controller.recordPointerCancel(const Offset(50, 50));

    expect(harness.controller.session!.events.length, before);
    expect(harness.controller.session!.ofType('swipe'), isEmpty);
  });

  test(
    'session_end does not emit orphan causal_only for cancelled route claim',
    () async {
      final harness = ReplayCoherenceHarness(
        settleDelay: const Duration(milliseconds: 100),
      );
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(12, 34));
      // Claim during down; do not await — cancel via session_end before publish.
      unawaited(
        harness.controller.route('route_push', harness.route('/claimed')),
      );
      await harness.pumpMicrotasks();
      await harness.controller.endSession();
      await harness.flushScheduler();

      expect(harness.controller.session!.ofType('tap'), isEmpty);
      expect(
        harness.controller.session!
            .ofType('route_change')
            .where((e) => e.data['route'] == '/claimed'),
        isEmpty,
      );
    },
  );

  test(
    'backgrounding drops pending claims so resume cannot attribute them',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(12, 34));
      harness.controller.recordAppLifecycleState(AppLifecycleState.paused);
      harness.controller.recordAppLifecycleState(AppLifecycleState.resumed);

      await harness.controller.route('route_push', harness.route('/after'));
      await harness.flushScheduler();

      final change = harness.controller.session!
          .ofType('route_change')
          .lastWhere((e) => e.data['route'] == '/after');
      expect(change.data['navigationOrigin'], 'automatic_or_unknown');
      expect(change.data['causeEventId'], isNull);
      expect(harness.controller.session!.ofType('tap'), isEmpty);
    },
  );

  test('duplicate pointer-down abandons the prior pending claim', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.controller.recordPointerDown(const Offset(10, 10));
    final firstBuffered = harness.controller.session!.ofType(
      'tap',
    ); // still deferred
    expect(firstBuffered, isEmpty);

    harness.controller.recordPointerDown(const Offset(20, 20));
    harness.controller.recordPointerUp(const Offset(20, 20));
    await harness.flushScheduler();

    final taps = harness.controller.session!.ofType('tap');
    expect(taps, hasLength(1));
    expect(taps.single.data['x'], 20);
    expect(taps.single.data['y'], 20);
  });

  test('deferred tap publish uses emission-time atMs for chronology', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.controller.recordPointerDown(const Offset(12, 34));
    harness.scheduler.advance(const Duration(milliseconds: 40));
    await harness.controller.route('route_push', harness.route('/dest'));
    await harness.flushScheduler();

    final events = harness.controller.session!.events;
    for (var i = 1; i < events.length; i++) {
      expect(events[i].atMs, greaterThanOrEqualTo(events[i - 1].atMs));
    }
    final tap = harness.controller.session!.ofType('tap').single;
    expect(tap.data['sampledAtMs'], isA<int>());
    expect(tap.atMs, greaterThanOrEqualTo(tap.data['sampledAtMs'] as int));
  });

  test('pointer-up promotes causal_only tap after pre-up claim', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.controller.recordPointerDown(const Offset(12, 34));
    await harness.controller.route('route_push', harness.route('/dest'));
    await harness.flushScheduler();
    expect(
      harness.controller.session!.ofType('tap').single.data['replayRole'],
      'causal_only',
    );

    harness.controller.recordPointerUp(const Offset(12, 34));
    await harness.flushScheduler();

    final tap = harness.controller.session!.ofType('tap').single;
    expect(tap.data['replayRole'], 'interaction');
    expect(tap.data['promotedFrom'], 'causal_only');
    final resolved = harness.controller.session!
        .ofType('tap_gesture_resolved')
        .single;
    expect(resolved.relatedEventId, tap.id);
    expect(resolved.data['promotesRelatedTap'], isTrue);
  });

  test('cancelled pointer cannot claim a route', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.controller.recordPointerDown(const Offset(12, 34));
    harness.controller.recordPointerCancel(const Offset(12, 34));
    expect(harness.controller.session!.ofType('tap'), isEmpty);
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

    await harness.controller.route('route_push', harness.route('/first'));
    await harness.pumpMicrotasks();
    final tap = harness.controller.session!.ofType('tap').single;

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

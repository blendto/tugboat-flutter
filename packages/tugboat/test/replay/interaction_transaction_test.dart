import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';
import 'package:tugboat/src/interaction_transaction.dart';

import '../helpers/replay_coherence_harness.dart';

Map<String, Object?> _roundTrip(Map<String, Object?> json) =>
    Map<String, Object?>.from(jsonDecode(jsonEncode(json)) as Map);

void expectInteractionV2Contract(TugboatEvent event) {
  expect(event.type, 'interaction');
  expect(event.stream, TugboatEventStream.semantic);
  expect(event.result, isNull);
  expect(event.targetAnchor, isNull);
  final data = event.data;
  expect(data['interactionSchema'], tugboatInteractionSchemaVersion);
  expect(data.containsKey('origin'), isFalse);
  expect(data.containsKey('result'), isFalse);
  expect(data.containsKey('attribution'), isFalse);
  expect(data.containsKey('evidenceEventIds'), isFalse);
  expect(data.containsKey('interactionId'), isFalse);
  expect(data.containsKey('stateAnchor'), isFalse);
  expect(data.containsKey('targetAnchor'), isFalse);
  expect(data.containsKey('position'), isFalse);
  if (data.containsKey('targetFingerprint')) {
    expect(data['targetFingerprint'], isA<String>());
  }
  final gesture = data['gesture'];
  if (gesture == 'cancelled') {
    expect(data.containsKey('payload'), isFalse);
  } else if (data.containsKey('payload')) {
    final payload = Map<String, Object?>.from(data['payload']! as Map);
    if (payload.containsKey('position')) {
      final position = Map<String, Object?>.from(payload['position']! as Map);
      expect(position['xNorm'], isA<num>());
      expect(position['yNorm'], isA<num>());
      expect(position.containsKey('normalizedX'), isFalse);
    }
    if (gesture == 'swipe' ||
        gesture == 'pan' ||
        gesture == 'zoom_in' ||
        gesture == 'zoom_out') {
      if (payload.containsKey('delta')) {
        final delta = Map<String, Object?>.from(payload['delta']! as Map);
        expect(delta['xNorm'], isA<num>());
        expect(delta['yNorm'], isA<num>());
      }
    }
    if (gesture == 'zoom_in' || gesture == 'zoom_out') {
      if (payload.containsKey('scale')) {
        expect(payload['scale'], isA<num>());
      }
    }
    if (gesture == 'scroll') {
      if (payload.containsKey('startOffset')) {
        expect(payload['startOffset'], isA<num>());
      }
      if (payload.containsKey('endOffset')) {
        expect(payload['endOffset'], isA<num>());
      }
    }
  }
  final encoded = utf8.encode(jsonEncode(event.toJson()));
  expect(encoded.length, lessThan(700));
}

extension on TugboatSession {
  List<TugboatEvent> semanticOfType(String type) => events
      .where((e) => e.type == type && e.stream == TugboatEventStream.semantic)
      .toList(growable: false);

  List<TugboatEvent> ofStream(TugboatEventStream stream) =>
      events.where((e) => e.stream == stream).toList(growable: false);
}

void main() {
  group('Interaction publication defaults', () {
    test('controller recordings emit canonical interactions', () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(8, 8));
      harness.controller.recordPointerUp(const Offset(8, 8));
      await harness.flushScheduler();

      final events = harness.controller.session!.events;
      expect(events.where((event) => event.type == 'interaction'), isNotEmpty);
    });
  });

  group('InteractionTransaction origin freeze (U1)', () {
    test('explicit origin target supplies the interaction fingerprint', () {
      const origin = InteractionOrigin(
        interactionId: 'interaction-1',
        route: '/origin',
        routeEpoch: 1,
        routeInstanceId: 'route-1',
        navigatorId: 'navigator-1',
        targetAnchor: TugboatTargetAnchor(fingerprint: 'origin-target'),
        captureCoordinate: TugboatCaptureCoordinate.unavailable(
          unavailableReason: 'boundary_unavailable',
        ),
        beforeFrame: null,
        atMs: 1,
        startPosition: Offset.zero,
        pointerGeneration: 1,
        captureSessionId: 'session-1',
      );

      final tx = InteractionTransaction(origin: origin, pointerId: 1);

      expect(
        buildInteractionV2Payload(tx)['targetFingerprint'],
        'origin-target',
      );
    });

    test(
      'origin screen/component survive route mutation before pointer-up',
      () async {
        final harness = ReplayCoherenceHarness();
        await harness.setUp();
        addTearDown(harness.dispose);

        harness.controller.debugSetCurrentRoute('/origin');

        harness.controller.recordPointerDown(const Offset(12, 34));
        await harness.controller.route('route_push', harness.route('/dest'));
        await harness.flushScheduler();
        harness.controller.recordPointerUp(const Offset(12, 34));
        await harness.flushScheduler();

        final interaction = harness.controller.session!
            .semanticOfType('interaction')
            .single;
        expectInteractionV2Contract(interaction);
        expect(interaction.data['route'], '/origin');
        expect(interaction.data.containsKey('targetFingerprint'), isFalse);
      },
    );

    test('lifecycle cancel finalizes without stranded transaction', () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(4, 4));
      harness.controller.recordPointerCancel(const Offset(4, 4));
      await harness.flushScheduler();

      final interactions = harness.controller.session!.semanticOfType(
        'interaction',
      );
      expect(interactions, hasLength(1));
      expect(interactions.single.data['gesture'], 'cancelled');
      expectInteractionV2Contract(interactions.single);
    });

    test('swipe terminal path clears causal route state', () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(4, 4));
      await harness.controller.route('route_push', harness.route('/next'));
      expect(harness.controller.debugCausalRouteCaptureCount, 1);

      harness.controller.markPendingTapAsSwipe(0);
      harness.controller.recordPointerUp(const Offset(80, 4));

      expect(harness.controller.debugCausalRouteCaptureCount, 0);
      expect(harness.controller.debugCausalRouteSupersededInteractionCount, 0);
    });

    test('pointer cancel clears causal route state', () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(4, 4));
      await harness.controller.route('route_push', harness.route('/next'));
      expect(harness.controller.debugCausalRouteCaptureCount, 1);

      harness.controller.recordPointerCancel(const Offset(4, 4));

      expect(harness.controller.debugCausalRouteCaptureCount, 0);
      expect(harness.controller.debugCausalRouteSupersededInteractionCount, 0);
    });

    test('duplicate pointer-down cancels prior and keeps one tap', () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(10, 10));
      harness.controller.recordPointerDown(const Offset(20, 20));
      harness.controller.recordPointerUp(const Offset(20, 20));
      await harness.flushScheduler();

      final interactions = harness.controller.session!.semanticOfType(
        'interaction',
      );
      expect(interactions, hasLength(2));
      expect(
        interactions.map((e) => e.data['gesture']),
        containsAll(['cancelled', 'tap']),
      );
      final tap = interactions.singleWhere((e) => e.data['gesture'] == 'tap');
      expectInteractionV2Contract(tap);
      if (tap.data.containsKey('payload')) {
        final payload = Map<String, Object?>.from(tap.data['payload']! as Map);
        if (payload.containsKey('position')) {
          final position = Map<String, Object?>.from(
            payload['position']! as Map,
          );
          expect(position['xNorm'], isA<num>());
        }
      }
    });

    test(
      'lifecycle clear of released claim publishes cancelled interaction',
      () async {
        final harness = ReplayCoherenceHarness(
          interactionClaimWindow: const Duration(milliseconds: 1250),
        );
        await harness.setUp();
        addTearDown(harness.dispose);

        harness.controller.recordPointerDown(const Offset(4, 4));
        harness.controller.recordPointerUp(const Offset(4, 4));
        // Still reconciling — backgrounding must terminalize the released tx.
        harness.controller.recordAppLifecycleState(AppLifecycleState.paused);
        await harness.flushScheduler();

        final cancelled = harness.controller.session!
            .semanticOfType('interaction')
            .where((e) => e.data['gesture'] == 'cancelled');
        expect(cancelled, isNotEmpty);
        expectInteractionV2Contract(cancelled.last);
        expect(cancelled.last.data['gesture'], 'cancelled');
      },
    );
  });

  group('Delayed reconciliation (U2)', () {
    test(
      'delayed route within claim window attributes as delayed_likely',
      () async {
        final harness = ReplayCoherenceHarness(
          interactionClaimWindow: const Duration(milliseconds: 1250),
        );
        await harness.setUp();
        addTearDown(harness.dispose);

        harness.controller.recordPointerDown(const Offset(12, 34));
        harness.controller.recordPointerUp(const Offset(12, 34));
        await harness.pumpMicrotasks();

        harness.scheduler.advance(const Duration(milliseconds: 500));
        await harness.controller.route('route_push', harness.route('/delayed'));
        await harness.flushScheduler();

        final change = harness.controller.session!
            .ofType('route_change')
            .lastWhere((e) => e.data['route'] == '/delayed');
        expect(change.data['navigationOrigin'], 'interaction');
        expect(change.data['interactionAttribution'], 'delayed_likely');
        expect(change.data['causedByInteractionId'], isNotNull);
        expect(
          change.data['causeEventId'],
          change.data['causedByInteractionId'],
        );

        final interaction = harness.controller.session!
            .semanticOfType('interaction')
            .single;
        expectInteractionV2Contract(interaction);
      },
    );

    test('route after claim window remains automatic', () async {
      final harness = ReplayCoherenceHarness(
        interactionClaimWindow: const Duration(milliseconds: 1250),
      );
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(12, 34));
      harness.controller.recordPointerUp(const Offset(12, 34));
      await harness.pumpMicrotasks();

      harness.scheduler.advance(const Duration(milliseconds: 1300));
      await harness.pumpMicrotasks();
      await harness.controller.route('route_push', harness.route('/late'));
      await harness.flushScheduler();

      final change = harness.controller.session!
          .ofType('route_change')
          .lastWhere((e) => e.data['route'] == '/late');
      expect(change.data['navigationOrigin'], 'automatic_or_unknown');
      expect(change.data['causeEventId'], isNull);
      expect(change.data['causedByInteractionId'], isNull);
    });

    test('two rapid taps cannot claim the same route twice', () async {
      final harness = ReplayCoherenceHarness(
        interactionClaimWindow: const Duration(milliseconds: 1250),
      );
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(10, 10), pointer: 1);
      harness.controller.recordPointerUp(const Offset(10, 10), pointer: 1);
      harness.controller.recordPointerDown(const Offset(20, 20), pointer: 2);
      harness.controller.recordPointerUp(const Offset(20, 20), pointer: 2);

      await harness.controller.route('route_push', harness.route('/only-one'));
      await harness.flushScheduler();

      final change = harness.controller.session!
          .ofType('route_change')
          .lastWhere((e) => e.data['route'] == '/only-one');
      expect(change.data['navigationOrigin'], 'automatic_or_unknown');
      expect(change.data['causeEventId'], isNull);
    });
  });

  group('Gesture classification (U3)', () {
    test('swipe emits zero semantic taps and one interaction', () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(10, 100));
      harness.controller.markPendingTapAsSwipe(0);
      harness.controller.recordPointerUp(const Offset(10, 40));
      await harness.flushScheduler();

      final interactions = harness.controller.session!.semanticOfType(
        'interaction',
      );
      expect(interactions, hasLength(1));
      expect(interactions.single.data['gesture'], anyOf('swipe', 'scroll'));
      expectInteractionV2Contract(interactions.single);
    });

    test('sub-slop movement remains one tap interaction', () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(10, 10));
      harness.controller.recordPointerUp(const Offset(12, 11));
      await harness.flushScheduler();

      final interactions = harness.controller.session!.semanticOfType(
        'interaction',
      );
      expect(interactions, hasLength(1));
      expect(interactions.single.data['gesture'], 'tap');
    });

    test('two-pointer pinch-out publishes one zoom_in interaction', () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(40, 100), pointer: 1);
      harness.controller.recordPointerDown(const Offset(80, 100), pointer: 2);
      harness.controller.markPendingScaleGesture(
        pointer: 1,
        gesture: InteractionGesture.zoomIn,
        scale: 1.8,
        pointerCount: 2,
      );
      harness.controller.suppressPendingPointer(2);
      harness.controller.recordPointerUp(const Offset(20, 100), pointer: 1);
      await harness.flushScheduler();

      final interactions = harness.controller.session!.semanticOfType(
        'interaction',
      );
      expect(interactions, hasLength(1));
      expect(interactions.single.data['gesture'], 'zoom_in');
      expectInteractionV2Contract(interactions.single);
      final payload = Map<String, Object?>.from(
        interactions.single.data['payload']! as Map,
      );
      expect(payload['scale'], 1.8);
      expect(payload['pointerCount'], 2);
    });

    test('two-pointer pinch-in publishes one zoom_out interaction', () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(20, 100), pointer: 1);
      harness.controller.recordPointerDown(const Offset(120, 100), pointer: 2);
      harness.controller.markPendingScaleGesture(
        pointer: 1,
        gesture: InteractionGesture.zoomOut,
        scale: 0.5,
        pointerCount: 2,
      );
      harness.controller.suppressPendingPointer(2);
      harness.controller.recordPointerUp(const Offset(50, 100), pointer: 1);
      await harness.flushScheduler();

      final interactions = harness.controller.session!.semanticOfType(
        'interaction',
      );
      expect(interactions, hasLength(1));
      expect(interactions.single.data['gesture'], 'zoom_out');
      expectInteractionV2Contract(interactions.single);
    });

    test('two-pointer translation publishes one pan interaction', () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(40, 40), pointer: 1);
      harness.controller.recordPointerDown(const Offset(80, 40), pointer: 2);
      harness.controller.markPendingScaleGesture(
        pointer: 1,
        gesture: InteractionGesture.pan,
        scale: 1,
        pointerCount: 2,
      );
      harness.controller.suppressPendingPointer(2);
      harness.controller.recordPointerUp(const Offset(40, 120), pointer: 1);
      await harness.flushScheduler();

      final interactions = harness.controller.session!.semanticOfType(
        'interaction',
      );
      expect(interactions, hasLength(1));
      expect(interactions.single.data['gesture'], 'pan');
      expectInteractionV2Contract(interactions.single);
      final payload = Map<String, Object?>.from(
        interactions.single.data['payload']! as Map,
      );
      expect(payload['pointerCount'], 2);
      expect(payload.containsKey('scale'), isFalse);
    });
  });

  group('Canonical publish and diagnostic isolation (U4)', () {
    test('serialization round-trip preserves facts-only v2 payload', () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(8, 8));
      harness.controller.recordPointerUp(const Offset(8, 8));
      await harness.flushScheduler();

      final interaction = harness.controller.session!
          .semanticOfType('interaction')
          .single;
      final json = _roundTrip(interaction.toJson());
      expect(json['type'], 'interaction');
      expect(json['stream'], tugboatEventStreamSemantic);
      final data = Map<String, Object?>.from(json['data']! as Map);
      expect(data['interactionSchema'], tugboatInteractionSchemaVersion);
      expect(data.containsKey('origin'), isFalse);
      expect(data.containsKey('result'), isFalse);
      expect(data.containsKey('attribution'), isFalse);
      expect(data.containsKey('evidenceEventIds'), isFalse);
      expect(data['gesture'], 'tap');
    });

    test('ten gestures publish ten canonical semantic interactions', () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      for (var i = 0; i < 10; i++) {
        final point = Offset(10.0 + i, 10.0);
        harness.controller.recordPointerDown(point);
        harness.controller.recordPointerUp(point);
      }
      await harness.flushScheduler();

      expect(
        harness.controller.session!.semanticOfType('interaction'),
        hasLength(10),
      );
    });

    test('capture diagnostics use diagnostic stream', () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      final request = harness.controller.debugRequestCapture(
        trigger: TugboatFrameTrigger.manual,
        force: true,
      );
      await request.resolution;
      await harness.flushScheduler();

      final diagnostics = harness.controller.session!.ofType(
        'capture_diagnostic',
      );
      expect(diagnostics, isNotEmpty);
      expect(
        diagnostics.every((e) => e.stream == TugboatEventStream.diagnostic),
        isTrue,
      );
      expect(
        harness.controller.session!
            .ofStream(TugboatEventStream.semantic)
            .where((e) => e.type == 'capture_diagnostic'),
        isEmpty,
      );
    });

    test(
      'route and state evidence are not semantic enrichment peers',
      () async {
        final harness = ReplayCoherenceHarness();
        await harness.setUp();
        addTearDown(harness.dispose);

        harness.controller.recordPointerDown(const Offset(8, 8));
        await harness.controller.route('route_push', harness.route('/dest'));
        harness.controller.recordPointerUp(const Offset(8, 8));
        await harness.flushScheduler();

        final routes = harness.controller.session!.ofType('route_change');
        expect(routes, isNotEmpty);
        expect(
          routes.every((e) => e.stream == TugboatEventStream.evidence),
          isTrue,
        );
        expect(routes.every((e) => !e.isEnrichmentCandidate), isTrue);

        final semantic = harness.controller.session!.ofStream(
          TugboatEventStream.semantic,
        );
        expect(semantic.where((e) => e.type == 'route_change'), isEmpty);
        expect(semantic.where((e) => e.type == 'interaction'), hasLength(1));
        expect(
          semantic
              .singleWhere((e) => e.type == 'interaction')
              .isEnrichmentCandidate,
          isTrue,
        );
      },
    );
  });
}

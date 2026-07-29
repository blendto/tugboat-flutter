import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import '../helpers/replay_coherence_harness.dart';

Map<String, Object?> _roundTrip(Map<String, Object?> json) =>
    Map<String, Object?>.from(jsonDecode(jsonEncode(json)) as Map);

extension on TugboatSession {
  List<TugboatEvent> semanticOfType(String type) => events
      .where((e) => e.type == type && e.stream == TugboatEventStream.semantic)
      .toList(growable: false);

  List<TugboatEvent> ofStream(TugboatEventStream stream) =>
      events.where((e) => e.stream == stream).toList(growable: false);
}

void main() {
  group('InteractionTransaction origin freeze (U1)', () {
    test(
      'origin screen/component survive route mutation before pointer-up',
      () async {
        final harness = ReplayCoherenceHarness();
        await harness.setUp();
        addTearDown(harness.dispose);

        harness.controller.debugSetCurrentRoute('/origin');
        harness.controller.debugFreezeStateAnchor = true;
        harness.controller.debugSetCurrentStateAnchor(
          const TugboatStateAnchor(
            signature: 'origin-sig',
            signatureConfidence: 'high',
            signatureParts: {'route': '/origin'},
          ),
        );

        harness.controller.recordPointerDown(const Offset(12, 34));
        await harness.controller.route('route_push', harness.route('/dest'));
        await harness.flushScheduler();
        harness.controller.recordPointerUp(const Offset(12, 34));
        await harness.flushScheduler();

        final interaction = harness.controller.session!
            .semanticOfType('interaction')
            .single;
        final origin = Map<String, Object?>.from(
          interaction.data['origin']! as Map,
        );
        expect(origin['route'], '/origin');
        final state = Map<String, Object?>.from(origin['stateAnchor']! as Map);
        expect(state['signature'], 'origin-sig');
        expect(interaction.targetAnchor?.fingerprint, isNull);
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
      expect(harness.controller.session!.ofType('tap'), isEmpty);
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
      final origin = Map<String, Object?>.from(tap.data['origin']! as Map);
      expect(
        Map<String, Object?>.from(origin['startPosition']! as Map)['x'],
        20.0,
      );
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
        final attribution = Map<String, Object?>.from(
          cancelled.last.data['attribution']! as Map,
        );
        expect(attribution['rejectionReason'], 'lifecycle');
      },
    );

    test(
      'canonical-only mode does not emit legacy promotion evidence',
      () async {
        final harness = ReplayCoherenceHarness(
          interactionPublishMode: TugboatInteractionPublishMode.canonicalOnly,
        );
        await harness.setUp();
        addTearDown(harness.dispose);

        harness.controller.recordPointerDown(const Offset(12, 34));
        await harness.controller.route('route_push', harness.route('/dest'));
        await harness.flushScheduler();
        harness.controller.recordPointerUp(const Offset(12, 34));
        await harness.flushScheduler();

        expect(
          harness.controller.session!.ofType('tap_gesture_resolved'),
          isEmpty,
        );
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
        final attribution = Map<String, Object?>.from(
          interaction.data['attribution']! as Map,
        );
        expect(attribution['kind'], anyOf('direct', 'delayed_likely'));
        final result = Map<String, Object?>.from(
          interaction.data['result']! as Map,
        );
        expect(result['status'], anyOf('navigated', 'changed', 'unknown'));
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

      expect(harness.controller.session!.ofType('tap'), isEmpty);
      expect(harness.controller.session!.ofType('tap_settled'), isEmpty);
      final interactions = harness.controller.session!.semanticOfType(
        'interaction',
      );
      expect(interactions, hasLength(1));
      expect(interactions.single.data['gesture'], anyOf('swipe', 'scroll'));
      final origin = Map<String, Object?>.from(
        interactions.single.data['origin']! as Map,
      );
      expect(origin['captureCoordinate'], isA<Map>());
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
  });

  group('Canonical publish and diagnostic isolation (U4)', () {
    test('serialization round-trip preserves origin and result', () async {
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
      expect(data['origin'], isA<Map>());
      expect(data['result'], isA<Map>());
      expect(data['attribution'], isA<Map>());
    });

    test('legacy peers are dual-written on legacy_projection stream', () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(8, 8));
      harness.controller.recordPointerUp(const Offset(8, 8));
      await harness.flushScheduler();

      final taps = harness.controller.session!.ofType('tap');
      final settles = harness.controller.session!.ofType('tap_settled');
      expect(taps, hasLength(1));
      expect(settles, hasLength(1));
      expect(taps.single.stream, TugboatEventStream.legacyProjection);
      expect(settles.single.stream, TugboatEventStream.legacyProjection);
      expect(taps.single.data['interactionId'], isNotNull);
      expect(
        settles.single.data['interactionId'],
        taps.single.data['interactionId'],
      );

      final semantic = harness.controller.session!.ofStream(
        TugboatEventStream.semantic,
      );
      expect(semantic.where((e) => e.type == 'tap'), isEmpty);
      expect(semantic.where((e) => e.type == 'tap_settled'), isEmpty);
      expect(semantic.where((e) => e.type == 'interaction'), hasLength(1));
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
        expect(
          harness.controller.session!
              .ofType('tap')
              .single
              .isEnrichmentCandidate,
          isFalse,
        );
      },
    );
  });
}

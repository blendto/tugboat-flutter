import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import 'helpers/replay_coherence_harness.dart';

/// Characterization coverage for SDK replay races (#5).
///
/// These tests reproduce current 0.4.x ordering/frame attribution behavior.
/// Where production is known-broken, the test asserts the broken sequence and
/// also records that [CoherenceInvariants] currently fail against it. Follow-up
/// issues (#6–#10) flip those invariants to true without rewriting the harness.
void main() {
  test(
    'tap with no navigation keeps linked settle evidence on one route',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      final originFrame = harness.seedRouteState(
        route: '/home',
        signature: 'sig-home',
        frameContentHash: 'home-pixels',
      );
      final routeEpoch = harness.controller.debugRouteEpoch;

      harness.controller.recordPointerDown(const Offset(12, 12));
      harness.controller.recordPointerUp(const Offset(12, 12));
      await harness.flushScheduler();

      final session = harness.controller.session!;
      final tap = session.ofType('tap').single;
      final settle = session.ofType('tap_settled').single;

      expect(settle.relatedEventId, tap.id);
      expect(tap.beforeFrame, originFrame);
      expect(settle.beforeFrame, originFrame);
      expect(settle.afterFrame, isNotNull);
      expect(settle.stateAnchor?.signature, 'sig-home');
      expect(
        CoherenceInvariants.tapSettleIsRouteCoherent(
          tap: tap,
          settle: settle,
          expectedRoute: '/home',
          expectedRouteEpoch: routeEpoch,
          frameProvenanceFor: harness.provenanceFor,
          expectedRouteSignature: 'sig-home',
        ),
        isTrue,
      );
    },
  );

  test(
    'tap that starts navigation awaits the matching route capture',
    () async {
      final harness = ReplayCoherenceHarness(
        settleDelay: const Duration(milliseconds: 50),
      );
      await harness.setUp();
      addTearDown(harness.dispose);

      final originFrame = harness.seedRouteState(
        route: '/scan',
        signature: 'sig-scan',
        frameContentHash: 'scan-pixels',
      );

      // Pointer-up enqueues tap_settled first.
      harness.controller.recordPointerDown(const Offset(20, 20));
      harness.controller.recordPointerUp(const Offset(20, 20));

      // Navigation callback arrives while settle is queued. The settle must
      // join this route epoch's capture instead of consuming the old frame.
      final routeFuture = harness.controller.route(
        'route_push',
        harness.route(
          '/home',
          transitionDuration: const Duration(milliseconds: 200),
        ),
      );

      // Pump queue work without advancing the route deadline: settle is now
      // waiting on the route barrier, not publishing stale evidence.
      await harness.pumpQueueWork();

      final midSession = harness.controller.session!;
      expect(midSession.ofType('tap_settled'), isEmpty);
      expect(
        midSession.ofType('route_change'),
        isEmpty,
        reason: 'route capture is still waiting on transition delay',
      );
      expect(harness.controller.debugRouteCapturePending, isTrue);

      await harness.flushScheduler();
      await routeFuture;

      final session = harness.controller.session!;
      final routeChange = session.ofType('route_change').single;
      final settle = session.ofType('tap_settled').single;
      expect(settle.relatedEventId, session.ofType('tap').single.id);
      expect(settle.afterFrame, routeChange.afterFrame);
      expect(settle.afterFrame, isNot(originFrame));
      expect(settle.result, TugboatInteractionResult.navigated);
      expect(routeChange.data['route'], '/home');
      expect(routeChange.afterFrame, isNot(originFrame));
      expect(
        session.events.map((event) => event.type).toList(),
        containsAll(['tap', 'tap_settled', 'route_change']),
      );
      final tapIndex = session.events.indexWhere((e) => e.type == 'tap');
      final settleIndex = session.events.indexWhere(
        (e) => e.type == 'tap_settled',
      );
      final routeIndex = session.events.indexWhere(
        (e) => e.type == 'route_change',
      );
      expect(tapIndex, lessThan(settleIndex));
      expect(routeIndex, lessThan(settleIndex));

      expect(
        CoherenceInvariants.navigationTapHasNoEarlyNoVisibleChange(
          events: session.events,
          tapEventId: session.ofType('tap').single.id,
          expectedDestinationRoute: '/home',
          expectedRouteEventId: routeChange.id,
        ),
        isTrue,
      );
    },
  );

  test(
    'navigation before pointer-up shares one route capture across settles',
    () async {
      final harness = ReplayCoherenceHarness(
        settleDelay: const Duration(milliseconds: 20),
      );
      await harness.setUp();
      addTearDown(harness.dispose);

      final originFrame = harness.seedRouteState(
        route: '/scan',
        signature: 'sig-scan',
      );
      final routeFuture = harness.controller.route(
        'route_push',
        harness.route(
          '/home',
          transitionDuration: const Duration(milliseconds: 20),
        ),
      );

      harness.controller.recordPointerDown(const Offset(10, 10), pointer: 1);
      harness.controller.recordPointerUp(const Offset(10, 10), pointer: 1);
      harness.controller.recordPointerDown(const Offset(20, 20), pointer: 2);
      harness.controller.recordPointerUp(const Offset(20, 20), pointer: 2);
      await harness.tick(const Duration(milliseconds: 19));
      expect(harness.controller.session!.ofType('tap_settled'), isEmpty);

      await harness.tick(const Duration(milliseconds: 1));
      await harness.flushScheduler();
      await routeFuture;

      final session = harness.controller.session!;
      final routeFrame = session.ofType('route_change').single.afterFrame;
      final settles = session.ofType('tap_settled');
      expect(settles, hasLength(2));
      expect(
        settles.map((event) => event.afterFrame),
        everyElement(routeFrame),
      );
      expect(
        harness.capturer.triggers.where(
          (trigger) => trigger == TugboatFrameTrigger.route,
        ),
        hasLength(1),
      );
      expect(routeFrame, isNot(originFrame));
    },
  );

  test('route just before tap settle boundary wins the capture slot', () async {
    final harness = ReplayCoherenceHarness(
      settleDelay: const Duration(milliseconds: 20),
    );
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.seedRouteState(route: '/scan', signature: 'sig-scan');
    harness.controller.recordPointerDown(const Offset(10, 10));
    harness.controller.recordPointerUp(const Offset(10, 10));
    await harness.tick(const Duration(milliseconds: 19));

    final routeFuture = harness.controller.route(
      'route_push',
      harness.route('/home'),
    );
    await harness.tick(const Duration(milliseconds: 1));
    await harness.flushScheduler();
    await routeFuture;

    final session = harness.controller.session!;
    final routeFrame = session.ofType('route_change').single.afterFrame;
    expect(session.ofType('tap_settled').single.afterFrame, routeFrame);
    expect(
      harness.capturer.triggers.where(
        (trigger) => trigger == TugboatFrameTrigger.route,
      ),
      hasLength(1),
    );
    expect(harness.capturer.triggers, isNot(contains(TugboatFrameTrigger.tap)));
  });

  test(
    'route starting during tap readback replaces the same-route observation',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.seedRouteState(route: '/scan', signature: 'sig-scan');
      harness.capturer.blockNext = true;
      harness.controller.recordPointerDown(const Offset(10, 10));
      harness.controller.recordPointerUp(const Offset(10, 10));
      await harness.pumpQueueWork();
      expect(harness.capturer.blockedCount, 1);

      final routeFuture = harness.controller.route(
        'route_push',
        harness.route('/home'),
      );
      harness.capturer.completeBlocked('stale-tap-frame');
      await harness.flushScheduler();
      await routeFuture;

      final session = harness.controller.session!;
      final routeChange = session.ofType('route_change').single;
      final settle = session.ofType('tap_settled').single;
      expect(settle.afterFrame, routeChange.afterFrame);
      expect(settle.stateAnchor, routeChange.stateAnchor);
      expect(settle.result, TugboatInteractionResult.navigated);
      expect(
        settle.data['settleObservation'],
        allOf(
          containsPair('route', '/home'),
          containsPair('routeEventId', routeChange.id),
        ),
      );
    },
  );

  test('successor chain resolves a waiting settle only to C', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);
    harness.seedRouteState(route: '/root', signature: 'root');
    harness.controller.recordPointerDown(const Offset(1, 1));
    final a = harness.controller.route('route_push', harness.route('/a'));
    harness.controller.recordPointerUp(const Offset(1, 1));
    final b = harness.controller.route('route_push', harness.route('/b'));
    final c = harness.controller.route('route_push', harness.route('/c'));
    await harness.flushScheduler();
    await Future.wait([a, b, c]);
    final changes = harness.controller.session!.ofType('route_change');
    expect(changes.map((event) => event.data['route']), ['/c']);
    expect(
      harness.controller.session!.ofType('tap_settled').single.afterFrame,
      changes.single.afterFrame,
    );
  });

  test('cancelling a settle deadline removes its scheduler entry', () async {
    final harness = ReplayCoherenceHarness(
      settleDelay: const Duration(milliseconds: 20),
    );
    await harness.setUp();
    addTearDown(harness.dispose);
    harness.controller.recordPointerDown(const Offset(1, 1));
    harness.controller.recordPointerUp(const Offset(1, 1));
    expect(harness.scheduler.pendingDelayCount, 1);
    await harness.controller.endSession();
    expect(harness.scheduler.pendingDelayCount, 0);
  });

  test('replacement during route readback suppresses old tap output', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);
    harness.controller.recordPointerDown(const Offset(1, 1));
    harness.controller.recordPointerUp(const Offset(1, 1));
    harness.capturer.blockNext = true;
    final route = harness.controller.route('route_push', harness.route('/old'));
    await harness.pumpQueueWork();
    expect(harness.capturer.blockedCount, 1);
    harness.controller.start(const Size(390, 844), 'replacement');
    harness.capturer.completeBlocked('old-frame');
    await route;
    await harness.flushScheduler();
    expect(harness.controller.session!.ofType('tap_settled'), isEmpty);
    expect(harness.controller.session!.ofType('route_change'), isEmpty);
  });

  test(
    'ending session during route readback suppresses waiting tap output',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.seedRouteState(route: '/scan', signature: 'sig-scan');
      harness.controller.recordPointerDown(const Offset(10, 10));
      harness.controller.recordPointerUp(const Offset(10, 10));
      harness.capturer.blockNext = true;
      final routeFuture = harness.controller.route(
        'route_push',
        harness.route('/home'),
      );
      await harness.pumpQueueWork();
      expect(harness.capturer.blockedCount, 1);
      await harness.controller.endSession();
      harness.capturer.completeBlocked('late-route-frame');
      await routeFuture;
      await harness.pumpQueueWork();

      expect(harness.controller.session!.ofType('tap_settled'), isEmpty);
      expect(harness.controller.session!.ofType('route_change'), isEmpty);
      expect(harness.controller.latestFrameId, isNot('late-route-frame'));
    },
  );

  test(
    'ending session invalidates an in-flight standalone tap capture',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      final originFrame = harness.seedRouteState(
        route: '/scan',
        signature: 'sig-scan',
      );
      final frameCount = harness.controller.session!.frames.length;
      harness.capturer.blockNext = true;
      harness.controller.recordPointerDown(const Offset(10, 10));
      harness.controller.recordPointerUp(const Offset(10, 10));
      await harness.pumpQueueWork();
      expect(harness.capturer.blockedCount, 1);

      await harness.controller.endSession();
      harness.capturer.completeBlocked('late-tap-frame');
      await harness.pumpQueueWork();

      final session = harness.controller.session!;
      expect(session.ofType('tap_settled'), isEmpty);
      expect(session.frames, hasLength(frameCount));
      expect(harness.controller.latestFrameId, originFrame);
    },
  );

  test(
    'backgrounding invalidates an in-flight standalone tap capture',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      final originFrame = harness.seedRouteState(
        route: '/scan',
        signature: 'sig-scan',
      );
      final frameCount = harness.controller.session!.frames.length;
      harness.capturer.blockNext = true;
      harness.controller.recordPointerDown(const Offset(10, 10));
      harness.controller.recordPointerUp(const Offset(10, 10));
      await harness.pumpQueueWork();
      expect(harness.capturer.blockedCount, 1);

      harness.controller.recordAppLifecycleState(AppLifecycleState.paused);
      harness.capturer.completeBlocked('late-background-frame');
      await harness.pumpQueueWork();

      final session = harness.controller.session!;
      expect(session.ofType('tap_settled'), isEmpty);
      expect(session.frames, hasLength(frameCount));
      expect(harness.controller.latestFrameId, originFrame);
    },
  );

  testWidgets('ending session suppresses blocked scroll_end output', (
    tester,
  ) async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    await _mountScrollableHarness(tester, harness);

    final originFrame = harness.seedRouteState(
      route: '/list',
      signature: 'sig-list',
    );
    harness.capturer.blockNext = true;
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await harness.pumpQueueWork();
    expect(harness.controller.session!.ofType('scroll_start'), hasLength(1));
    expect(harness.capturer.blockedCount, 1);

    await harness.controller.endSession();
    harness.capturer.completeBlocked('late-scroll-frame');
    await harness.pumpQueueWork();

    expect(harness.controller.session!.ofType('scroll_end'), isEmpty);
    expect(harness.controller.latestFrameId, originFrame);
    harness.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('backgrounding suppresses blocked scroll_end output', (
    tester,
  ) async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    await _mountScrollableHarness(tester, harness);

    final originFrame = harness.seedRouteState(
      route: '/list',
      signature: 'sig-list',
    );
    harness.capturer.blockNext = true;
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await harness.pumpQueueWork();
    expect(harness.controller.session!.ofType('scroll_start'), hasLength(1));
    expect(harness.capturer.blockedCount, 1);

    harness.controller.recordAppLifecycleState(AppLifecycleState.paused);
    harness.capturer.completeBlocked('late-scroll-frame');
    await harness.pumpQueueWork();

    expect(harness.controller.session!.ofType('scroll_end'), isEmpty);
    expect(harness.controller.latestFrameId, originFrame);
    harness.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  test('ending a session cancels a tap waiting on route capture', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.seedRouteState(route: '/scan', signature: 'sig-scan');
    harness.controller.recordPointerDown(const Offset(10, 10));
    harness.controller.recordPointerUp(const Offset(10, 10));
    final routeFuture = harness.controller.route(
      'route_push',
      harness.route(
        '/home',
        transitionDuration: const Duration(milliseconds: 20),
      ),
    );
    await harness.controller.endSession();
    await routeFuture;
    await harness.pumpQueueWork();

    expect(harness.controller.session!.ofType('tap_settled'), isEmpty);
    expect(harness.controller.session!.ofType('route_change'), isEmpty);
  });

  test(
    'replacement session rejects a tap waiting on old route capture',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.seedRouteState(route: '/scan', signature: 'sig-scan');
      harness.controller.recordPointerDown(const Offset(10, 10));
      harness.controller.recordPointerUp(const Offset(10, 10));
      final routeFuture = harness.controller.route(
        'route_push',
        harness.route('/home'),
      );
      await harness.pumpQueueWork();
      harness.controller.start(const Size(390, 844), 'replacement');
      await routeFuture;
      await harness.flushScheduler();

      expect(harness.controller.session!.ofType('tap_settled'), isEmpty);
      expect(harness.controller.session!.ofType('route_change'), isEmpty);
    },
  );

  group('navigationTapHasNoEarlyNoVisibleChange ordering', () {
    TugboatEvent syntheticEvent({
      required String id,
      required String type,
      required int atMs,
      String? relatedEventId,
      TugboatInteractionResult? result,
      Map<String, Object?> data = const {},
    }) {
      return TugboatEvent(
        id: id,
        atMs: atMs,
        type: type,
        relatedEventId: relatedEventId,
        result: result,
        data: data,
      );
    }

    test(
      'fails when route_change precedes tap_settled with noVisibleChange',
      () {
        final events = [
          syntheticEvent(id: 'tap-1', type: 'tap', atMs: 100),
          syntheticEvent(
            id: 'route-1',
            type: 'route_change',
            atMs: 150,
            data: {'route': '/home'},
          ),
          syntheticEvent(
            id: 'settle-1',
            type: 'tap_settled',
            atMs: 200,
            relatedEventId: 'tap-1',
            result: TugboatInteractionResult.noVisibleChange,
          ),
        ];
        expect(
          CoherenceInvariants.navigationTapHasNoEarlyNoVisibleChange(
            events: events,
            tapEventId: 'tap-1',
            expectedDestinationRoute: '/home',
            expectedRouteEventId: 'route-1',
          ),
          isFalse,
        );
      },
    );

    test(
      'fails when route_change follows tap_settled with noVisibleChange',
      () {
        final events = [
          syntheticEvent(id: 'tap-1', type: 'tap', atMs: 100),
          syntheticEvent(
            id: 'settle-1',
            type: 'tap_settled',
            atMs: 150,
            relatedEventId: 'tap-1',
            result: TugboatInteractionResult.noVisibleChange,
          ),
          syntheticEvent(
            id: 'route-1',
            type: 'route_change',
            atMs: 200,
            data: {'route': '/home'},
          ),
        ];
        expect(
          CoherenceInvariants.navigationTapHasNoEarlyNoVisibleChange(
            events: events,
            tapEventId: 'tap-1',
            expectedDestinationRoute: '/home',
            expectedRouteEventId: 'route-1',
          ),
          isFalse,
        );
      },
    );

    test('fails when destination route_change is missing', () {
      final events = [
        syntheticEvent(id: 'tap-1', type: 'tap', atMs: 100),
        syntheticEvent(
          id: 'settle-1',
          type: 'tap_settled',
          atMs: 150,
          relatedEventId: 'tap-1',
          result: TugboatInteractionResult.noVisibleChange,
        ),
      ];
      expect(
        CoherenceInvariants.navigationTapHasNoEarlyNoVisibleChange(
          events: events,
          tapEventId: 'tap-1',
          expectedDestinationRoute: '/home',
          expectedRouteEventId: 'route-1',
        ),
        isFalse,
      );
    });

    test('fails when expected route event id does not match destination', () {
      final events = [
        syntheticEvent(id: 'tap-1', type: 'tap', atMs: 100),
        syntheticEvent(
          id: 'route-1',
          type: 'route_change',
          atMs: 120,
          data: {'route': '/settings'},
        ),
        syntheticEvent(
          id: 'settle-1',
          type: 'tap_settled',
          atMs: 180,
          relatedEventId: 'tap-1',
          result: TugboatInteractionResult.changed,
        ),
      ];
      expect(
        CoherenceInvariants.navigationTapHasNoEarlyNoVisibleChange(
          events: events,
          tapEventId: 'tap-1',
          expectedDestinationRoute: '/home',
          expectedRouteEventId: 'route-1',
        ),
        isFalse,
      );
    });

    test('fails when route_change occurs before tap', () {
      final events = [
        syntheticEvent(
          id: 'route-1',
          type: 'route_change',
          atMs: 50,
          data: {'route': '/home'},
        ),
        syntheticEvent(id: 'tap-1', type: 'tap', atMs: 100),
        syntheticEvent(
          id: 'settle-1',
          type: 'tap_settled',
          atMs: 180,
          relatedEventId: 'tap-1',
          result: TugboatInteractionResult.changed,
        ),
      ];
      expect(
        CoherenceInvariants.navigationTapHasNoEarlyNoVisibleChange(
          events: events,
          tapEventId: 'tap-1',
          expectedDestinationRoute: '/home',
          expectedRouteEventId: 'route-1',
        ),
        isFalse,
      );
    });

    test(
      'passes when matching route exists and settle is not noVisibleChange',
      () {
        final events = [
          syntheticEvent(id: 'tap-1', type: 'tap', atMs: 100),
          syntheticEvent(
            id: 'route-1',
            type: 'route_change',
            atMs: 120,
            data: {'route': '/home'},
          ),
          syntheticEvent(
            id: 'settle-1',
            type: 'tap_settled',
            atMs: 180,
            relatedEventId: 'tap-1',
            result: TugboatInteractionResult.changed,
          ),
        ];
        expect(
          CoherenceInvariants.navigationTapHasNoEarlyNoVisibleChange(
            events: events,
            tapEventId: 'tap-1',
            expectedDestinationRoute: '/home',
            expectedRouteEventId: 'route-1',
          ),
          isTrue,
        );
      },
    );
  });

  test(
    'destination tap while route capture pending leaves before frame unavailable',
    () async {
      final harness = ReplayCoherenceHarness(
        settleDelay: const Duration(milliseconds: 40),
      );
      await harness.setUp();
      addTearDown(harness.dispose);

      final originFrame = harness.seedRouteState(
        route: '/scan',
        signature: 'sig-scan',
        frameContentHash: 'scan-pixels',
      );

      final routeFuture = harness.controller.route(
        'route_push',
        harness.route(
          '/home',
          transitionDuration: const Duration(milliseconds: 150),
        ),
      );
      expect(harness.controller.debugRouteCapturePending, isTrue);
      expect(harness.controller.currentRoute, '/home');
      expect(harness.controller.latestFrameId, originFrame);

      // Destination UI semantics are already visible, but the route capture has
      // not published a destination frame yet.
      harness.controller.debugSetCurrentStateAnchor(
        const TugboatStateAnchor(
          signature: 'sig-home',
          signatureParts: {'route': '/home'},
        ),
      );

      harness.controller.recordPointerDown(const Offset(30, 30));
      harness.controller.recordPointerUp(const Offset(30, 30));

      // The origin frame is globally latest but belongs to a different route
      // epoch, so it must not be attached to destination UI evidence.
      final session = harness.controller.session!;
      final destinationTap = session.ofType('tap').single;
      expect(destinationTap.beforeFrame, isNull);
      expect(destinationTap.data['frameAttachment'], {
        'before': 'unavailable',
        'reason': 'no_compatible_frame',
      });
      expect(destinationTap.stateAnchor?.signature, 'sig-home');
      expect(harness.controller.debugRouteCapturePending, isTrue);
      expect(
        CoherenceInvariants.actionFrameMatchesRoute(
          action: destinationTap,
          originFrameId: originFrame,
          destinationFrameId: 'destination-frame-not-captured-yet',
          frameProvenanceFor: harness.provenanceFor,
        ),
        isFalse,
      );

      await harness.flushScheduler();
      await routeFuture;

      final routeChange = session.ofType('route_change').single;
      final destinationFrame = routeChange.afterFrame!;
      expect(destinationFrame, isNot(originFrame));
      expect(routeChange.data['route'], '/home');
      expect(
        CoherenceInvariants.actionFrameMatchesRoute(
          action: destinationTap,
          originFrameId: originFrame,
          destinationFrameId: destinationFrame,
          frameProvenanceFor: harness.provenanceFor,
        ),
        isFalse,
        reason:
            'tap has no compatible before frame while destination frame exists',
      );

      // After the blocking route wait finishes, settle may run with a newer
      // frame — the cross-route attribution already happened on the tap.
      final destinationSettle = session.ofType('tap_settled').single;
      expect(destinationSettle.relatedEventId, destinationTap.id);
      expect(destinationSettle.beforeFrame, isNull);
    },
  );

  test('frame provenance is immutable across compatible reuse', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    final frame = harness.seedRouteState(
      route: '/home',
      signature: 'sig-home',
      frameContentHash: 'same-pixels',
    );
    final beforeReuse = Map<String, Object?>.from(
      harness.controller.debugFrameProvenance(frame)!,
    );

    expect(harness.controller.debugReuseFrameForCurrentRoute(frame), frame);
    final afterReuse = harness.controller.debugFrameProvenance(frame)!;
    expect(afterReuse['captureSessionId'], beforeReuse['captureSessionId']);
    expect(afterReuse['routeEpoch'], beforeReuse['routeEpoch']);
    expect(afterReuse['route'], beforeReuse['route']);
    expect(afterReuse['requestedAtMs'], beforeReuse['requestedAtMs']);
    expect(afterReuse['completedAtMs'], beforeReuse['completedAtMs']);
    expect(afterReuse['reuseReason'], 'content_hash');
    expect(afterReuse['reusedFromFrameId'], frame);
  });

  test('first interaction records explicit frame unavailability', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    // Start a replacement session and inspect the synchronous interaction
    // before its initial capture pump can run.
    harness.capturer.blockNext = true;
    harness.controller.start(const Size(390, 844), 'test');
    harness.controller.debugSetCurrentRoute('/home');
    harness.controller.debugSetCurrentStateAnchor(
      const TugboatStateAnchor(
        signature: 'sig-home',
        signatureParts: {'route': '/home'},
      ),
    );

    harness.controller.recordPointerDown(const Offset(4, 4));
    final tap = harness.controller.session!.ofType('tap').single;
    expect(tap.beforeFrame, isNull);
    expect(tap.data['frameAttachment'], {
      'before': 'unavailable',
      'reason': 'no_frame_available',
    });

    await harness.controller.endSession();
  });

  test('capture coalescing preserves incompatible request order', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    for (final (pointer, route) in [(1, '/a'), (2, '/b'), (3, '/a')]) {
      harness.controller.debugSetCurrentRoute(route);
      harness.controller.debugSetCurrentStateAnchor(
        TugboatStateAnchor(
          signature: 'sig-$route',
          signatureParts: {'route': route},
        ),
      );
      harness.controller.recordPointerDown(
        Offset(pointer.toDouble(), pointer.toDouble()),
        pointer: pointer,
      );
      harness.controller.recordPointerUp(
        Offset(pointer.toDouble(), pointer.toDouble()),
        pointer: pointer,
      );
    }

    expect(harness.controller.debugScheduledCaptureRoutes, ['/a', '/b', '/a']);

    await harness.controller.endSession();
  });

  test('tap settle keeps the state observed with its after frame', () async {
    final harness = ReplayCoherenceHarness();
    await harness.setUp();
    addTearDown(harness.dispose);

    harness.seedRouteState(route: '/home', signature: 'sig-before');
    harness.capturer.frameFactory = (trigger, force) {
      harness.controller.debugSetCurrentStateAnchor(
        const TugboatStateAnchor(
          signature: 'sig-captured',
          signatureParts: {'route': '/home'},
        ),
      );
      final frame = harness.controller.debugSeedFrame(
        contentHash: 'captured-pixels',
        trigger: trigger,
      );
      // Simulate controller state advancing after readback but before the
      // settle event is admitted to the serialized mutation queue.
      harness.controller.debugSetCurrentStateAnchor(
        const TugboatStateAnchor(
          signature: 'sig-advanced',
          signatureParts: {'route': '/home'},
        ),
      );
      return frame;
    };

    harness.controller.recordPointerDown(const Offset(12, 12));
    harness.controller.recordPointerUp(const Offset(12, 12));
    await harness.flushScheduler();

    final settle = harness.controller.session!.ofType('tap_settled').single;
    expect(settle.afterFrame, isNotNull);
    expect(settle.stateAnchor?.signature, 'sig-captured');
    expect(harness.controller.currentStateAnchor?.signature, 'sig-advanced');
    expect(
      harness.controller.debugFrameProvenance(
        settle.afterFrame!,
      )!['completionStateSignature'],
      'sig-captured',
    );
  });

  test(
    'same-route no-op requires matching semantic and visual evidence',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      final beforeFrame = harness.seedRouteState(
        route: '/home',
        signature: 'sig-home',
        frameContentHash: 'same-pixels',
      );
      harness.capturer.frameFactory = (trigger, force) => harness.controller
          .debugSeedFrame(contentHash: 'same-pixels', trigger: trigger);

      harness.controller.recordPointerDown(const Offset(12, 12));
      harness.controller.recordPointerUp(const Offset(12, 12));
      await harness.flushScheduler();

      final settle = harness.controller.session!.ofType('tap_settled').single;
      expect(settle.beforeFrame, beforeFrame);
      expect(settle.afterFrame, isNot(beforeFrame));
      expect(settle.result, TugboatInteractionResult.noVisibleChange);
      final observation = settle.data['settleObservation'] as Map;
      expect(observation['semantic'], {
        'changed': false,
        'evidence': 'state_signature',
        'reason': 'same_signature',
      });
      expect(observation['visual'], {
        'changed': false,
        'evidence': 'content_hash',
        'reason': 'same_frame',
      });
    },
  );

  test(
    'same pixels on a new route receive distinct frame provenance',
    () async {
      final harness = ReplayCoherenceHarness(
        settleDelay: const Duration(milliseconds: 20),
      );
      await harness.setUp();
      addTearDown(harness.dispose);

      final origin = harness.seedRouteState(
        route: '/origin',
        signature: 'sig-origin',
        frameContentHash: 'same-pixels',
      );
      final route = harness.controller.route(
        'route_push',
        harness.route(
          '/destination',
          transitionDuration: const Duration(milliseconds: 20),
        ),
      );
      harness.controller.debugSetCurrentStateAnchor(
        const TugboatStateAnchor(
          signature: 'sig-destination',
          signatureParts: {'route': '/destination'},
        ),
      );
      final destination = harness.controller.debugSeedFrame(
        contentHash: 'same-pixels',
        trigger: TugboatFrameTrigger.route,
      );

      expect(destination, isNot(origin));
      expect(
        harness.controller.debugFrameProvenance(origin),
        containsPair('route', '/origin'),
      );
      expect(
        harness.controller.debugFrameProvenance(destination),
        allOf(
          containsPair('route', '/destination'),
          containsPair('routeEpoch', 1),
        ),
      );
      expect(harness.controller.debugReuseFrameForCurrentRoute(origin), isNull);

      await harness.controller.endSession();
      await route;
    },
  );

  test('push replace and pop never attach the prior route frame', () async {
    for (final transition in [
      ('route_push', '/pushed'),
      ('route_replace', '/replacement'),
      ('route_pop', '/revealed'),
    ]) {
      final harness = ReplayCoherenceHarness(
        settleDelay: const Duration(milliseconds: 20),
      );
      await harness.setUp();
      final origin = harness.seedRouteState(
        route: '/origin',
        signature: 'sig-origin',
      );
      final route = harness.controller.route(
        transition.$1,
        harness.route(
          transition.$2,
          transitionDuration: const Duration(milliseconds: 20),
        ),
      );
      harness.controller.debugSetCurrentStateAnchor(
        TugboatStateAnchor(
          signature: 'sig-${transition.$2}',
          signatureParts: {'route': transition.$2},
        ),
      );

      harness.controller.recordPointerDown(const Offset(8, 8));
      final tap = harness.controller.session!.ofType('tap').single;
      expect(tap.beforeFrame, isNull, reason: transition.$1);
      expect(tap.beforeFrame, isNot(origin), reason: transition.$1);
      expect(tap.data['frameAttachment'], {
        'before': 'unavailable',
        'reason': 'no_compatible_frame',
      });

      await harness.controller.endSession();
      await route;
      harness.dispose();
    }
  });

  test('trimmed provenance remains a tombstone and is never reused', () async {
    final harness = ReplayCoherenceHarness(maxFrames: 1);
    await harness.setUp();
    addTearDown(harness.dispose);

    final first = harness.seedRouteState(
      route: '/home',
      signature: 'sig-home',
      frameContentHash: 'first-pixels',
    );
    harness.controller.recordPointerDown(const Offset(1, 1), pointer: 1);
    final retainedTap = harness.controller.session!.ofType('tap').single;
    expect(retainedTap.beforeFrame, first);

    final second = harness.controller.debugSeedFrame(
      contentHash: 'second-pixels',
    );
    expect(harness.controller.session!.frames.map((frame) => frame.id), [
      second,
    ]);
    expect(
      harness.controller.debugFrameProvenance(first),
      containsPair('available', false),
    );
    expect(retainedTap.beforeFrame, first);
    expect(harness.controller.debugReuseFrameForCurrentRoute(first), isNull);

    harness.controller.recordPointerDown(const Offset(2, 2), pointer: 2);
    final latestTap = harness.controller.session!.ofType('tap').last;
    expect(latestTap.beforeFrame, second);
  });

  test('unreferenced trimmed provenance is pruned', () async {
    final harness = ReplayCoherenceHarness(maxFrames: 1);
    await harness.setUp();
    addTearDown(harness.dispose);

    final first = harness.seedRouteState(
      route: '/home',
      signature: 'sig-home',
      frameContentHash: 'first-pixels',
    );
    final second = harness.controller.debugSeedFrame(
      contentHash: 'second-pixels',
    );

    expect(harness.controller.session!.frames.map((frame) => frame.id), [
      second,
    ]);
    expect(harness.controller.debugFrameProvenance(first), isNull);
    expect(harness.controller.debugFrameProvenanceCount, 1);
    expect(harness.controller.latestFrameId, second);
  });

  test('trimming every frame clears latest frame metadata', () async {
    final harness = ReplayCoherenceHarness(maxFrames: 0);
    await harness.setUp();
    addTearDown(harness.dispose);

    final removed = harness.seedRouteState(
      route: '/home',
      signature: 'sig-home',
      frameContentHash: 'pixels',
    );

    expect(harness.controller.session!.frames, isEmpty);
    expect(harness.controller.latestFrameId, isNull);
    expect(harness.controller.debugFrameProvenance(removed), isNull);
    expect(harness.controller.debugFrameProvenanceCount, 0);
    expect(harness.controller.debugFrameReuseObservationCount, 0);
  });

  test(
    'actionFrameMatchesRoute rejects a third unrelated frame family',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      final originFrame = harness.seedRouteState(
        route: '/scan',
        signature: 'sig-scan',
        frameContentHash: 'scan-pixels',
      );
      final unrelatedFrame = harness.controller.debugSeedFrame(
        contentHash: 'scan-pixels',
      );
      harness.registerFrameProvenance(
        unrelatedFrame,
        route: '/settings',
        routeEpoch: 1,
      );
      final destinationFrame = harness.controller.debugSeedFrame(
        contentHash: 'home-pixels',
        trigger: TugboatFrameTrigger.route,
      );
      harness.registerFrameProvenance(
        destinationFrame,
        route: '/home',
        routeEpoch: 2,
      );

      harness.controller.debugSetCurrentStateAnchor(
        const TugboatStateAnchor(
          signature: 'sig-home',
          signatureParts: {'route': '/home'},
        ),
      );

      harness.controller.recordPointerDown(const Offset(30, 30));
      harness.controller.recordPointerUp(const Offset(30, 30));
      await harness.flushScheduler();

      final session = harness.controller.session!;
      final tap = session.ofType('tap').single;
      final tapWithUnrelatedFrame = TugboatEvent(
        id: tap.id,
        atMs: tap.atMs,
        type: tap.type,
        stateAnchor: tap.stateAnchor,
        targetAnchor: tap.targetAnchor,
        beforeFrame: unrelatedFrame,
        data: tap.data,
      );

      expect(unrelatedFrame, isNot(originFrame));
      expect(unrelatedFrame, isNot(destinationFrame));
      expect(
        CoherenceInvariants.actionFrameMatchesRoute(
          action: tapWithUnrelatedFrame,
          originFrameId: originFrame,
          destinationFrameId: destinationFrame,
          frameProvenanceFor: harness.provenanceFor,
        ),
        isFalse,
        reason:
            'unrelated frame must not pass merely by matching destination pixels',
      );
      expect(
        CoherenceInvariants.actionFrameMatchesRoute(
          action: TugboatEvent(
            id: tap.id,
            atMs: tap.atMs,
            type: tap.type,
            beforeFrame: destinationFrame,
          ),
          originFrameId: originFrame,
          destinationFrameId: destinationFrame,
          frameProvenanceFor: harness.provenanceFor,
        ),
        isTrue,
      );
    },
  );

  test(
    'route capture after navigation stamps destination route provenance',
    () async {
      final harness = ReplayCoherenceHarness(
        settleDelay: const Duration(milliseconds: 30),
      );
      await harness.setUp();
      addTearDown(harness.dispose);

      final originFrame = harness.seedRouteState(
        route: '/scan',
        signature: 'sig-scan',
        frameContentHash: 'scan-pixels',
      );
      final originEpoch = harness.controller.debugRouteEpoch;

      final routeFuture = harness.controller.route(
        'route_push',
        harness.route(
          '/home',
          transitionDuration: const Duration(milliseconds: 100),
        ),
      );
      expect(harness.controller.currentRoute, '/home');
      expect(
        harness.controller.currentStateAnchor?.signatureParts['route'],
        '/scan',
        reason:
            'debugFreezeStateAnchor retains origin semantics during capture',
      );

      await harness.flushScheduler();
      await routeFuture;

      final routeChange = harness.controller.session!
          .ofType('route_change')
          .single;
      final destinationFrame = routeChange.afterFrame!;
      final destinationEpoch = harness
          .provenanceFor(destinationFrame)!
          .routeEpoch;

      expect(harness.provenanceFor(originFrame)!.route, '/scan');
      expect(harness.provenanceFor(originFrame)!.routeEpoch, originEpoch);
      expect(harness.provenanceFor(destinationFrame)!.route, '/home');
      expect(destinationEpoch, greaterThan(originEpoch));
      expect(destinationEpoch, harness.controller.debugRouteEpoch);
    },
  );

  test(
    'rapid route changes cancel obsolete epochs without hanging the queue',
    () async {
      final harness = ReplayCoherenceHarness(
        settleDelay: const Duration(milliseconds: 30),
      );
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.seedRouteState(route: '/', signature: 'sig-root');

      final first = harness.controller.route(
        'route_push',
        harness.route(
          '/a',
          transitionDuration: const Duration(milliseconds: 200),
        ),
      );
      final firstEpoch = harness.controller.debugRouteEpoch;
      await harness.tick(const Duration(milliseconds: 10));

      final second = harness.controller.route(
        'route_push',
        harness.route(
          '/b',
          transitionDuration: const Duration(milliseconds: 20),
        ),
      );
      expect(harness.controller.debugRouteEpoch, greaterThan(firstEpoch));

      await harness.flushScheduler();
      await first;
      await second;

      expect(harness.controller.currentRoute, '/b');
      final changes = harness.controller.session!.ofType('route_change');
      expect(
        changes.where((event) => event.data['route'] == '/a'),
        isEmpty,
        reason: 'superseded epoch must not emit',
      );
      expect(changes.last.data['route'], '/b');
      expect(harness.controller.debugRouteCapturePending, isFalse);
      expect(harness.scheduler.hasPendingDelays, isFalse);
    },
  );

  test(
    'route transition delay does not block later serialized controller work',
    () async {
      final harness = ReplayCoherenceHarness(
        settleDelay: const Duration(milliseconds: 30),
      );
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.seedRouteState(route: '/', signature: 'sig-root');
      unawaited(
        harness.controller.route(
          'route_push',
          harness.route(
            '/destination',
            transitionDuration: const Duration(milliseconds: 200),
          ),
        ),
      );

      var laterTaskRan = false;
      unawaited(
        harness.controller.debugEnqueueTask('later_probe', () async {
          laterTaskRan = true;
        }),
      );
      await harness.pumpQueueWork();

      expect(
        laterTaskRan,
        isTrue,
        reason: 'the transition deadline must be outside the serialized queue',
      );
    },
  );

  test(
    'ending a session cancels its pending route deadline and completes it',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      final pending = harness.controller.route(
        'route_push',
        harness.route(
          '/destination',
          transitionDuration: const Duration(milliseconds: 200),
        ),
      );
      await harness.controller.endSession();
      await pending;

      expect(harness.controller.debugRouteCapturePending, isFalse);
      expect(harness.scheduler.pendingDelayCount, 0);
      await harness.flushScheduler();
      expect(
        harness.controller.session!.ofType('route_change'),
        isEmpty,
        reason: 'a completed session must not receive a deferred route event',
      );
    },
  );

  test(
    'starting a replacement session cancels the prior route deadline',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      final prior = harness.controller.route(
        'route_push',
        harness.route(
          '/stale',
          transitionDuration: const Duration(milliseconds: 200),
        ),
      );
      harness.controller.start(const Size(390, 844), 'test');
      await prior;

      expect(harness.controller.debugRouteCapturePending, isFalse);
      expect(harness.scheduler.pendingDelayCount, 0);
      await harness.flushScheduler();
      expect(
        harness.controller.session!.ofType('route_change'),
        isEmpty,
        reason: 'a deferred callback from the old session must be inert',
      );
    },
  );

  test(
    'disposing completes a pending route waiter without advancing time',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();

      final pending = harness.controller.route(
        'route_push',
        harness.route(
          '/destination',
          transitionDuration: const Duration(milliseconds: 200),
        ),
      );
      harness.dispose();
      await pending;

      expect(harness.controller.debugRouteCapturePending, isFalse);
      expect(harness.scheduler.pendingDelayCount, 0);
    },
  );

  test(
    'backgrounding cancels pending route work without a late route event',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      final pending = harness.controller.route(
        'route_push',
        harness.route(
          '/destination',
          transitionDuration: const Duration(milliseconds: 200),
        ),
      );
      harness.controller.recordAppLifecycleState(AppLifecycleState.paused);
      await pending;

      expect(harness.controller.debugRouteCapturePending, isFalse);
      expect(harness.scheduler.pendingDelayCount, 0);
      expect(harness.controller.session!.ofType('route_change'), isEmpty);
    },
  );

  test(
    'superseding a route during capture emits only the replacement',
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
      harness.capturer.completeBlocked();
      await harness.flushScheduler();
      await replacement;

      final changes = harness.controller.session!.ofType('route_change');
      expect(changes.map((event) => event.data['route']), ['/replacement']);
      expect(harness.controller.debugRouteCapturePending, isFalse);
    },
  );

  test(
    'ending a session cancels an in-flight route capture without late output',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      final frameCount = harness.controller.session!.frames.length;
      harness.capturer.blockNext = true;
      final pending = harness.controller.route(
        'route_push',
        harness.route('/destination'),
      );
      await harness.pumpQueueWork();
      expect(harness.capturer.blockedCount, 1);

      await harness.controller.endSession();
      await pending;
      harness.capturer.completeBlocked('cancelled-route-frame');
      await harness.pumpQueueWork();

      expect(harness.controller.session!.frames.length, frameCount);
      expect(harness.controller.session!.ofType('route_change'), isEmpty);
      expect(harness.controller.latestFrameId, isNot('cancelled-route-frame'));
    },
  );

  test(
    'blocked route readback times out without publishing a late frame',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.seedRouteState(route: '/origin', signature: 'origin');
      harness.controller.recordPointerDown(const Offset(10, 10));
      harness.capturer.blockNext = true;
      final route = harness.controller.route(
        'route_push',
        harness.route('/blocked'),
      );
      harness.controller.recordPointerUp(const Offset(10, 10));
      await harness.pumpQueueWork();
      expect(harness.capturer.blockedCount, 1);
      final frameBeforeTimeout = harness.controller.latestFrameId;

      // Private controller timeout: 5 seconds. The controllable scheduler
      // proves this is a bounded barrier rather than a wall-clock test.
      await harness.tick(const Duration(seconds: 5));
      await route;
      await harness.pumpQueueWork();

      final change = harness.controller.session!.ofType('route_change').single;
      expect(change.afterFrame, isNull);
      expect(change.result, TugboatInteractionResult.unknown);
      expect(change.data['captureOutcome'], 'timed_out');
      final timedOutSettle = harness.controller.session!
          .ofType('tap_settled')
          .single;
      expect(timedOutSettle.result, TugboatInteractionResult.unknown);
      expect(timedOutSettle.afterFrame, isNull);
      expect(timedOutSettle.stateAnchor, change.stateAnchor);
      expect(
        timedOutSettle.data['settleObservation'],
        allOf(
          containsPair('captureOutcome', 'timed_out'),
          containsPair('routeEventId', change.id),
        ),
      );
      expect(harness.controller.latestFrameId, frameBeforeTimeout);

      harness.capturer.completeBlocked('late-route-frame');
      await harness.pumpQueueWork();
      expect(harness.controller.latestFrameId, frameBeforeTimeout);
      expect(harness.controller.session!.ofType('route_change'), hasLength(1));
    },
  );

  test(
    'absolute route timeout releases waiters before queued admission',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      final predecessor = Completer<void>();
      unawaited(
        harness.controller.debugEnqueueTask(
          'unrelated predecessor',
          () => predecessor.future,
        ),
      );
      await harness.pumpQueueWork();

      harness.controller.recordPointerDown(const Offset(10, 10));
      final route = harness.controller.route(
        'route_push',
        harness.route('/queued'),
      );
      harness.controller.recordPointerUp(const Offset(10, 10));
      await harness.tick(const Duration(seconds: 5));
      await route;
      await harness.pumpQueueWork();

      // Neither route finalization nor tap_settled can enter the blocked
      // queue, but their waiters have already reached a terminal outcome.
      expect(harness.controller.debugActiveTapSettleCount, 0);
      final changes = harness.controller.session!.ofType('route_change');
      expect(changes, hasLength(1));
      expect(changes.single.data['captureOutcome'], 'timed_out');
      expect(harness.controller.session!.ofType('tap_settled'), hasLength(1));

      predecessor.complete();
      await harness.flushScheduler();
      expect(harness.controller.session!.ofType('route_change'), hasLength(1));
      expect(harness.controller.session!.ofType('tap_settled'), hasLength(1));
    },
  );

  test(
    'timed-out route never transfers its waiting tap to a later route',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.controller.recordPointerDown(const Offset(10, 10));
      harness.capturer.blockNext = true;
      final timedOut = harness.controller.route(
        'route_push',
        harness.route('/timed-out'),
      );
      harness.controller.recordPointerUp(const Offset(10, 10));
      await harness.pumpQueueWork();
      await harness.tick(const Duration(seconds: 5));
      await timedOut;

      final next = harness.controller.route(
        'route_push',
        harness.route('/next'),
      );
      await harness.pumpQueueWork();
      final timedOutSettle = harness.controller.session!
          .ofType('tap_settled')
          .single;
      expect(timedOutSettle.afterFrame, isNull);
      expect(
        timedOutSettle.data['settleObservation'],
        containsPair('route', '/timed-out'),
      );
      // Releasing the stale platform readback lets the scheduler run B, but the
      // timed-out A waiter must remain terminal rather than joining B.
      harness.capturer.completeBlocked('late-a-frame');
      await harness.flushScheduler();
      await next;

      final changes = harness.controller.session!.ofType('route_change');
      expect(changes.map((event) => event.data['route']), [
        '/timed-out',
        '/next',
      ]);
      expect(harness.controller.session!.ofType('tap_settled'), hasLength(1));
    },
  );

  test(
    'replacement session rejects a capture from the prior route epoch',
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

      harness.controller.start(const Size(390, 844), 'replacement');
      await stale;
      harness.capturer.completeBlocked('stale-route-frame');
      await harness.flushScheduler();

      expect(harness.controller.session!.ofType('route_change'), isEmpty);
      expect(harness.controller.latestFrameId, isNot('stale-route-frame'));
      expect(
        harness.controller.session!.frames
            .map((frame) => frame.id)
            .contains('stale-route-frame'),
        isFalse,
      );
    },
  );

  test(
    'route capture failure completes the deadline and later route work',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.capturer.failNext = true;
      final failedCapture = harness.controller.route(
        'route_push',
        harness.route(
          '/first',
          transitionDuration: const Duration(milliseconds: 200),
        ),
      );
      harness.scheduler.advance(const Duration(milliseconds: 700));
      await harness.pumpQueueWork();
      await failedCapture;

      final recovery = harness.controller.route(
        'route_replace',
        harness.route('/recovered'),
      );
      await harness.flushScheduler();
      await recovery;

      final changes = harness.controller.session!.ofType('route_change');
      expect(changes.map((event) => event.data['route']), [
        '/first',
        '/recovered',
      ]);
      expect(changes.first.afterFrame, isNull);
      expect(changes.first.data['captureOutcome'], 'failed');
      expect(harness.controller.debugRouteCapturePending, isFalse);
      expect(harness.scheduler.pendingDelayCount, 0);
    },
  );

  test(
    'modal push/pop and replacement share the route ordering path',
    () async {
      final harness = ReplayCoherenceHarness(
        settleDelay: const Duration(milliseconds: 20),
      );
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.seedRouteState(route: '/home', signature: 'sig-home');

      final push = harness.controller.route(
        'route_push',
        harness.route(
          '/modal',
          transitionDuration: const Duration(milliseconds: 40),
        ),
      );
      await harness.flushScheduler();
      await push;

      final pop = harness.controller.route(
        'route_pop',
        harness.route(
          '/home',
          transitionDuration: const Duration(milliseconds: 40),
        ),
      );
      await harness.flushScheduler();
      await pop;

      final replace = harness.controller.route(
        'route_replace',
        harness.route(
          '/home2',
          transitionDuration: const Duration(milliseconds: 40),
        ),
      );
      await harness.flushScheduler();
      await replace;

      final navigations = harness.controller.session!
          .ofType('route_change')
          .map((event) => event.data['navigation'])
          .toList();
      expect(navigations, ['route_push', 'route_pop', 'route_replace']);
      expect(harness.controller.currentRoute, '/home2');
      expect(
        harness.controller.session!
            .ofType('route_change')
            .every((event) => event.afterFrame != null),
        isTrue,
      );
    },
  );

  test(
    'signature-only change with unchanged frame currently reports changed',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      final frame = harness.seedRouteState(
        route: '/home',
        signature: 'sig-before',
        frameContentHash: 'same-pixels',
      );

      harness.controller.recordPointerDown(const Offset(8, 8));
      harness.controller.debugSetCurrentStateAnchor(
        const TugboatStateAnchor(
          signature: 'sig-after',
          signatureParts: {'route': '/home'},
        ),
      );
      harness.capturer.frameFactory = (trigger, force) => harness.controller
          .debugSeedFrame(contentHash: 'same-pixels', trigger: trigger);
      harness.controller.recordPointerUp(const Offset(8, 8));
      await harness.flushScheduler();

      final settle = harness.controller.session!.ofType('tap_settled').single;
      expect(settle.beforeFrame, frame);
      expect(settle.afterFrame, isNot(frame));
      expect(settle.result, TugboatInteractionResult.changed);
      expect(
        settle.stateAnchor?.signature,
        'sig-after',
        reason: 'same-route semantic evidence is captured with the settle',
      );
      expect((settle.data['settleObservation'] as Map)['visual'], {
        'changed': false,
        'evidence': 'content_hash',
        'reason': 'same_frame',
      });
    },
  );

  test(
    'capture failure does not strand queued waiters or later settles',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.seedRouteState(route: '/home', signature: 'sig-home');
      harness.capturer.failNext = true;

      harness.controller.recordPointerDown(const Offset(4, 4));
      harness.controller.recordPointerUp(const Offset(4, 4));
      await harness.flushScheduler();

      final settles = harness.controller.session!.ofType('tap_settled');
      expect(settles, hasLength(1));
      expect(settles.single.afterFrame, isNull);
      expect(settles.single.result, TugboatInteractionResult.unknown);
      expect(settles.single.data['frameAttachment'], {
        'after': 'unavailable',
        'reason': 'capture_unavailable',
      });
      final observation = settles.single.data['settleObservation'] as Map;
      expect(observation['captureOutcome'], 'failed');
      expect(observation['captureFailure'], 'capture_unavailable');
      expect(observation['visual'], {
        'changed': null,
        'evidence': 'unavailable',
        'reason': 'unavailable',
      });
      expect(harness.controller.debugCaptureInFlight, isFalse);
      expect(harness.controller.debugRouteCapturePending, isFalse);

      harness.controller.recordPointerDown(const Offset(5, 5));
      harness.controller.recordPointerUp(const Offset(5, 5));
      await harness.flushScheduler();
      expect(harness.controller.session!.ofType('tap_settled'), hasLength(2));
    },
  );

  test(
    'blocked capture eventually completes waiters without wall-clock sleeps',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.seedRouteState(route: '/home', signature: 'sig-home');
      harness.capturer.blockNext = true;

      harness.controller.recordPointerDown(const Offset(6, 6));
      harness.controller.recordPointerUp(const Offset(6, 6));
      await harness.pumpQueueWork();

      expect(harness.capturer.blockedCount, 1);
      expect(harness.controller.session!.ofType('tap_settled'), isEmpty);
      expect(harness.controller.debugCaptureInFlight, isTrue);

      harness.capturer.completeBlocked();
      await harness.flushScheduler();

      expect(harness.controller.session!.ofType('tap_settled'), hasLength(1));
      expect(harness.controller.debugCaptureInFlight, isFalse);
    },
  );

  testWidgets('widget-backed tap and settle share target anchor fingerprint', (
    tester,
  ) async {
    final harness = ReplayCoherenceHarness();
    await harness.setUpWidgetBacked(tester);

    harness.seedRouteState(route: '/home', signature: 'sig-home');

    final tapPoint = harness.targetTapPosition(tester);
    harness.controller.recordPointerDown(tapPoint);
    harness.controller.recordPointerUp(tapPoint);
    await harness.flushScheduler();

    final session = harness.controller.session!;
    final tap = session.ofType('tap').single;
    final settle = session.ofType('tap_settled').single;
    final inventory = session.ofType('scene_inventory').last;
    final inventorySignature =
        inventory.stateAnchor?.signature ??
        inventory.data['stateSignature'] as String?;

    expect(tap.targetAnchor, isNotNull);
    expect(tap.targetAnchor!.fingerprint, isNotNull);
    expect(tap.targetAnchor!.fingerprint, isNotEmpty);
    expect(tap.targetAnchor!.canonicalPath, isNotEmpty);
    expect(tap.targetAnchor!.role, 'button');
    expect(tap.targetAnchor!.widgetType, isNot('RepaintBoundary'));
    expect(tap.stateAnchor?.signature, inventorySignature);
    expect(settle.targetAnchor, isNotNull);
    expect(settle.targetAnchor!.fingerprint, tap.targetAnchor!.fingerprint);
    expect(settle.targetAnchor!.canonicalPath, tap.targetAnchor!.canonicalPath);
    expect(settle.targetAnchor!.role, 'button');
    expect(settle.relatedEventId, tap.id);

    harness.controller.recordPointerDown(tapPoint);
    harness.controller.recordPointerUp(tapPoint);
    await harness.flushScheduler();

    final repeatTap = session.ofType('tap').last;
    expect(repeatTap.targetAnchor!.fingerprint, tap.targetAnchor!.fingerprint);
    expect(
      repeatTap.targetAnchor!.canonicalPath,
      tap.targetAnchor!.canonicalPath,
    );
    expect(repeatTap.targetAnchor!.role, tap.targetAnchor!.role);

    await harness.tearDownWidgetBacked(tester);
  });

  testWidgets('widget-backed pending-route tap keeps linked target anchor', (
    tester,
  ) async {
    final harness = ReplayCoherenceHarness(
      settleDelay: const Duration(milliseconds: 40),
    );
    await harness.setUpWidgetBacked(tester);

    harness.seedRouteState(route: '/scan', signature: 'sig-scan');

    final routeFuture = harness.controller.route(
      'route_push',
      harness.route(
        '/home',
        transitionDuration: const Duration(milliseconds: 150),
      ),
    );
    expect(harness.controller.debugRouteCapturePending, isTrue);

    final tapPoint = harness.targetTapPosition(tester);
    harness.controller.recordPointerDown(tapPoint);
    harness.controller.recordPointerUp(tapPoint);
    await harness.pumpQueueWork();

    final session = harness.controller.session!;
    final tap = session.ofType('tap').single;
    final inventory = session.ofType('scene_inventory').last;
    final inventorySignature =
        inventory.stateAnchor?.signature ??
        inventory.data['stateSignature'] as String?;

    expect(tap.targetAnchor, isNotNull);
    expect(tap.targetAnchor!.fingerprint, isNotNull);
    expect(tap.targetAnchor!.fingerprint, isNotEmpty);
    expect(tap.targetAnchor!.canonicalPath, isNotEmpty);
    expect(tap.targetAnchor!.role, 'button');
    expect(tap.stateAnchor?.signature, inventorySignature);

    await harness.flushScheduler();
    await routeFuture;

    final settle = session.ofType('tap_settled').single;
    expect(settle.targetAnchor, isNotNull);
    expect(settle.targetAnchor!.fingerprint, tap.targetAnchor!.fingerprint);
    expect(settle.targetAnchor!.canonicalPath, tap.targetAnchor!.canonicalPath);
    expect(settle.targetAnchor!.role, tap.targetAnchor!.role);
    expect(settle.relatedEventId, tap.id);

    await harness.tearDownWidgetBacked(tester);
  });

  testWidgets(
    'pointer-down swipe classification suppresses tap_settled with provenance',
    (tester) async {
      final harness = ReplayCoherenceHarness();
      await harness.setUpWidgetBacked(tester);

      final originFrame = harness.seedRouteState(
        route: '/home',
        signature: 'sig-home',
        frameContentHash: 'home-pixels',
      );

      final start = harness.targetTapPosition(tester);
      // Controller classification seam — not InputCapture slop detection.
      await harness.recordClassifiedSwipe(start);

      final session = harness.controller.session!;
      final tap = session.ofType('tap').single;
      final swipe = session.ofType('swipe').single;
      final eventTypes = session.events.map((event) => event.type).toList();

      expect(session.ofType('tap_settled'), isEmpty);
      expect(eventTypes.indexOf('tap'), lessThan(eventTypes.indexOf('swipe')));
      expect(swipe.relatedEventId, tap.id);
      expect(swipe.beforeFrame, originFrame);
      expect(swipe.stateAnchor?.signature, tap.stateAnchor?.signature);
      expect(tap.targetAnchor, isNotNull);
      expect(swipe.targetAnchor, isNotNull);
      expect(swipe.targetAnchor!.fingerprint, tap.targetAnchor!.fingerprint);
      expect(
        swipe.targetAnchor!.canonicalPath,
        tap.targetAnchor!.canonicalPath,
      );
      expect(swipe.data['startX'], closeTo(start.dx, 0.01));
      expect(swipe.data['startY'], closeTo(start.dy, 0.01));
      expect(swipe.data['scrolled'], isFalse);

      await harness.tearDownWidgetBacked(tester);
    },
  );

  test(
    'harness timeout seam cancels blocked capture without seeding success',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);

      harness.seedRouteState(route: '/home', signature: 'sig-home');
      harness.capturer.blockNext = true;
      // Production has no capture timeout/cancel yet (#10); harness-only seam.
      harness.capturer.autoReleaseBlockedAfter = const Duration(
        milliseconds: 50,
      );

      final framesBefore = harness.controller.session!.frames.length;

      harness.controller.recordPointerDown(const Offset(6, 6));
      harness.controller.recordPointerUp(const Offset(6, 6));
      await harness.pumpQueueWork();

      expect(harness.capturer.blockedCount, 1);
      expect(harness.controller.session!.ofType('tap_settled'), isEmpty);
      expect(harness.controller.debugCaptureInFlight, isTrue);

      await harness.tick(const Duration(milliseconds: 50));
      await harness.flushScheduler();

      final session = harness.controller.session!;
      expect(session.ofType('tap_settled'), hasLength(1));
      expect(harness.capturer.blockedCount, isZero);
      expect(harness.controller.debugCaptureInFlight, isFalse);
      expect(session.frames.length, framesBefore);
      expect(
        session.frames.any(
          (frame) => frame.contentHash.startsWith('timeout-released'),
        ),
        isFalse,
      );
    },
  );
}

Future<void> _mountScrollableHarness(
  WidgetTester tester,
  ReplayCoherenceHarness harness,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollStartNotification) {
            harness.controller.recordScrollStart(
              scrollContext: notification.context,
              metrics: notification.metrics,
              depth: notification.depth,
            );
          } else if (notification is ScrollUpdateNotification) {
            harness.controller.recordScrollUpdate(
              scrollContext: notification.context,
              metrics: notification.metrics,
            );
          } else if (notification is ScrollEndNotification) {
            harness.controller.recordScrollEnd(
              scrollContext: notification.context,
              metrics: notification.metrics,
            );
          }
          return false;
        },
        child: ListView(
          children: List<Widget>.generate(
            30,
            (index) => SizedBox(height: 80, child: Text('$index')),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

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
  test('tap with no navigation keeps linked settle evidence on one route', () async {
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
  });

  test(
    'tap that starts navigation currently emits noVisibleChange before route_change',
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

      // Navigation callback arrives while settle is queued: route updates and
      // pending flag flip immediately; capture waits on the serialized queue.
      final routeFuture = harness.controller.route(
        'route_push',
        harness.route(
          '/home',
          transitionDuration: const Duration(milliseconds: 200),
        ),
      );

      // Pump queue work without awaiting the parked route delay.
      await harness.pumpQueueWork();

      final midSession = harness.controller.session!;
      final settle = midSession.ofType('tap_settled').single;
      expect(settle.relatedEventId, midSession.ofType('tap').single.id);
      expect(
        settle.result,
        TugboatInteractionResult.noVisibleChange,
        reason:
            'pending-route settle skips state refresh and reuses origin frame',
      );
      expect(
        settle.afterFrame,
        originFrame,
        reason: 'tap_settled consumed _latestFrameId while route capture pending',
      );
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
      expect(settleIndex, lessThan(routeIndex));

      // Desired invariant fails on this known broken sequence.
      expect(
        CoherenceInvariants.navigationTapHasNoEarlyNoVisibleChange(
          events: session.events,
          tapEventId: session.ofType('tap').single.id,
          expectedDestinationRoute: '/home',
          expectedRouteEventId: routeChange.id,
        ),
        isFalse,
      );
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

    test('fails when route_change precedes tap_settled with noVisibleChange', () {
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
    });

    test('fails when route_change follows tap_settled with noVisibleChange', () {
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
    });

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

    test('passes when matching route exists and settle is not noVisibleChange', () {
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
    });
  });

  test(
    'destination tap while route capture pending carries previous route frame',
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

      // The tap is recorded synchronously against the still-origin latest frame
      // while the route capture remains pending. Settle itself is queued behind
      // the blocking transition wait (see #6), so characterize the tap event.
      final session = harness.controller.session!;
      final destinationTap = session.ofType('tap').single;
      expect(destinationTap.beforeFrame, originFrame);
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
        reason: 'tap still carries origin frame while destination frame exists',
      );

      // After the blocking route wait finishes, settle may run with a newer
      // frame — the cross-route attribution already happened on the tap.
      final destinationSettle = session.ofType('tap_settled').single;
      expect(destinationSettle.relatedEventId, destinationTap.id);
      expect(destinationSettle.beforeFrame, originFrame);
    },
  );

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

  test('modal push/pop and replacement share the route ordering path', () async {
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
  });

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
      harness.capturer.frameFactory = (trigger, force) => frame;
      harness.controller.recordPointerUp(const Offset(8, 8));
      await harness.flushScheduler();

      final settle = harness.controller.session!.ofType('tap_settled').single;
      expect(settle.beforeFrame, frame);
      expect(settle.afterFrame, frame);
      expect(settle.result, TugboatInteractionResult.changed);
      expect(settle.stateAnchor?.signature, 'sig-after');
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
    addTearDown(harness.dispose);

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
  });

  testWidgets(
    'widget-backed pending-route tap keeps linked target anchor',
    (tester) async {
      final harness = ReplayCoherenceHarness(
        settleDelay: const Duration(milliseconds: 40),
      );
      await harness.setUpWidgetBacked(tester);
      addTearDown(harness.dispose);

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
      expect(
        settle.targetAnchor!.canonicalPath,
        tap.targetAnchor!.canonicalPath,
      );
      expect(settle.targetAnchor!.role, tap.targetAnchor!.role);
      expect(settle.relatedEventId, tap.id);
    },
  );

  testWidgets(
    'pointer-down swipe classification suppresses tap_settled with provenance',
    (tester) async {
      final harness = ReplayCoherenceHarness();
      await harness.setUpWidgetBacked(tester);
      addTearDown(harness.dispose);

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
      expect(swipe.targetAnchor!.canonicalPath, tap.targetAnchor!.canonicalPath);
      expect(swipe.data['startX'], closeTo(start.dx, 0.01));
      expect(swipe.data['startY'], closeTo(start.dy, 0.01));
      expect(swipe.data['scrolled'], isFalse);
    },
  );
}

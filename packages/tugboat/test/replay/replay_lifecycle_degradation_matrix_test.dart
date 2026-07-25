import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import '../helpers/replay_coherence_harness.dart';

List<TugboatEvent> _diagnostics(TugboatSession session) => session.events
    .where((event) => event.type == 'capture_diagnostic')
    .toList(growable: false);

TugboatEvent _diagnosticForRequest(TugboatSession session, String requestId) =>
    _diagnostics(
      session,
    ).singleWhere((event) => event.data['requestId'] == requestId);

void main() {
  testWidgets(
    'external-picker-shaped lifecycle transition resumes with fresh correlated evidence',
    (tester) async {
      final harness = ReplayCoherenceHarness();
      await harness.setUpWidgetBacked(tester);
      try {
        final origin = harness.seedRouteState(
          route: '/compose',
          signature: 'compose',
          frameContentHash: 'compose-before-picker',
        );
        final session = harness.controller.session!;
        final diagnosticStart = _diagnostics(session).length;
        final routeEpoch = harness.controller.debugRouteEpoch;

        // This is the lifecycle sequence produced when a platform picker takes
        // focus. Keep the mounted boundary alive: the picker is external, not
        // a Navigator route that Tugboat can capture directly.
        harness.controller.recordAppLifecycleState(AppLifecycleState.inactive);
        harness.controller.recordAppLifecycleState(AppLifecycleState.paused);
        harness.controller.recordAppLifecycleState(AppLifecycleState.resumed);
        await harness.pumpQueueWork();
        await harness.flushScheduler();

        final resumedDiagnostic = _diagnostics(session)
            .sublist(diagnosticStart)
            .singleWhere((event) => event.data['trigger'] == 'lifecycle');
        expect(resumedDiagnostic.data['outcome'], 'fresh_accepted');
        expect(resumedDiagnostic.data['routeEpoch'], routeEpoch);
        expect(resumedDiagnostic.data['captureSessionId'], session.id);
        expect(resumedDiagnostic.afterFrame, isNot(origin));
        expect(
          harness.provenanceFor(resumedDiagnostic.afterFrame)?.route,
          '/compose',
        );
        expect(
          harness.provenanceFor(resumedDiagnostic.afterFrame)?.routeEpoch,
          routeEpoch,
        );
        expect(
          session.events.map((event) => event.type),
          containsAllInOrder(<String>[
            'app_inactive',
            'app_backgrounded',
            'app_foregrounded',
            'capture_diagnostic',
          ]),
        );
        expect(
          CoherenceInvariants.hasChronologicalChain(events: session.events),
          isTrue,
        );
      } finally {
        await harness.tearDownWidgetBacked(tester);
      }
    },
  );

  test(
    'deactivation and replacement cancel an in-flight capture once',
    () async {
      final deactivation = ReplayCoherenceHarness();
      await deactivation.setUp();
      addTearDown(deactivation.dispose);
      final activeSession = deactivation.controller.session!;
      final origin = deactivation.seedRouteState(
        route: '/picker-launcher',
        signature: 'picker-launcher',
      );
      deactivation.capturer.blockNext = true;
      final suspendedRequest = deactivation.controller.debugRequestCapture(
        force: true,
        relatedEventId: 'launch-picker',
      );
      await deactivation.pumpQueueWork();
      expect(deactivation.capturer.blockedCount, 1);

      deactivation.controller.recordAppLifecycleState(AppLifecycleState.paused);
      final suspendedResolution = await suspendedRequest.resolution;
      deactivation.capturer.completeBlocked('late-paused-frame');
      await deactivation.pumpQueueWork();

      expect(suspendedResolution['outcome'], 'cancelled');
      expect(suspendedResolution['cancellationReason'], 'lifecycle_deactivate');
      expect(
        _diagnosticForRequest(
          activeSession,
          suspendedResolution['requestId']! as String,
        ).data['cancellationReason'],
        'lifecycle_deactivate',
      );
      expect(
        _diagnostics(activeSession).where(
          (event) =>
              event.data['requestId'] == suspendedResolution['requestId'],
        ),
        hasLength(1),
      );
      expect(
        activeSession.frames.map((frame) => frame.id),
        isNot(contains('late-paused-frame')),
      );
      expect(deactivation.controller.latestFrameId, origin);

      final replacement = ReplayCoherenceHarness();
      await replacement.setUp();
      addTearDown(replacement.dispose);
      final oldSession = replacement.controller.session!;
      replacement.seedRouteState(route: '/old', signature: 'old');
      replacement.capturer.blockNext = true;
      final oldRequest = replacement.controller.debugRequestCapture(
        force: true,
      );
      await replacement.pumpQueueWork();
      expect(replacement.capturer.blockedCount, 1);

      replacement.controller.start(const Size(390, 844), 'replacement');
      final replacementResolution = await oldRequest.resolution;
      replacement.capturer.completeBlocked('late-replaced-frame');
      await replacement.pumpQueueWork();

      expect(replacementResolution['outcome'], 'cancelled');
      expect(
        replacementResolution['cancellationReason'],
        'session_replacement',
      );
      expect(
        _diagnostics(oldSession).where(
          (event) =>
              event.data['requestId'] == replacementResolution['requestId'],
        ),
        hasLength(1),
      );
      expect(
        replacement.controller.session!.frames.map((frame) => frame.id),
        isNot(contains('late-replaced-frame')),
      );
      expect(replacement.controller.debugCaptureInFlight, isFalse);
    },
  );

  testWidgets(
    'degraded screenshot budget preserves a fresh critical route capture',
    (tester) async {
      final harness = ReplayCoherenceHarness(
        // A zero-sized budget becomes degraded after the first real
        // readback. Route captures are fresh-paint work and must remain
        // eligible even while reusable work would be skipped.
        screenshotBudget: const TugboatScreenshotBudgetConfig(budgetMicros: 0),
      );
      await harness.setUpWidgetBacked(tester);
      try {
        final origin = harness.seedRouteState(
          route: '/home',
          signature: 'home',
          frameContentHash: 'home-pixels',
        );
        final session = harness.controller.session!;

        // Exercise the real ScreenshotCapturer path. The harness's synthetic
        // executor deliberately bypasses budget accounting, so remove it only
        // after the widget boundary is mounted and the seeded origin is stable.
        harness.controller.debugExecuteCapture = null;
        final primingCapture = harness.controller.debugRequestCapture(
          force: true,
        );
        var primingComplete = false;
        primingCapture.resolution.then((_) => primingComplete = true);
        await harness.pumpQueueWork();
        // A real RepaintBoundary readback finishes outside FakeAsync. Drive
        // the frame it subscribed to, yield the encoder a bounded turn, then
        // commit its completion back through the widget test binding.
        await tester.pump();
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        await tester.pump();
        expect(primingComplete, isTrue);
        final primingResolution = await primingCapture.resolution;
        expect(primingResolution['outcome'], 'fresh_accepted');
        expect(
          harness.controller.healthSnapshot().screenshots.degraded,
          isTrue,
        );

        final route = harness.controller.route(
          'route_push',
          harness.route('/details'),
        );
        var routeComplete = false;
        route.then((_) => routeComplete = true);
        await harness.pumpQueueWork();
        await tester.pump();
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        await tester.pump();
        expect(routeComplete, isTrue);
        await route;

        final change = session.ofType('route_change').single;
        final diagnostic = _diagnostics(
          session,
        ).singleWhere((event) => event.data['trigger'] == 'route');
        expect(diagnostic.data['outcome'], 'fresh_accepted');
        expect(diagnostic.afterFrame, isNotNull);
        expect(change.data['route'], '/details');
        expect(change.afterFrame, diagnostic.afterFrame);
        expect(change.afterFrame, isNot(origin));
        expect(
          diagnostic.data['routeEpoch'],
          harness.controller.debugRouteEpoch,
        );
        expect(diagnostic.data['captureSessionId'], session.id);
        expect(harness.provenanceFor(change.afterFrame)?.route, '/details');
        expect(
          harness.provenanceFor(change.afterFrame)?.routeEpoch,
          harness.controller.debugRouteEpoch,
        );
        expect(
          CoherenceInvariants.hasNoCrossRouteFrameSubstitution(
            event: change,
            originFrameId: origin,
            destinationFrameId: change.afterFrame,
            frameProvenanceFor: harness.provenanceFor,
          ),
          isTrue,
        );
      } finally {
        await harness.tearDownWidgetBacked(tester);
      }
    },
  );

  test(
    'route capture timeout drains work and a later route captures fresh evidence',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);
      final origin = harness.seedRouteState(route: '/home', signature: 'home');
      final session = harness.controller.session!;
      harness.capturer.blockNext = true;

      final timedOutRoute = harness.controller.route(
        'route_push',
        harness.route('/picker'),
      );
      await harness.pumpQueueWork();
      expect(harness.capturer.blockedCount, 1);

      harness.scheduler.advance(const Duration(seconds: 5));
      await harness.pumpQueueWork();
      await timedOutRoute;

      final timedOutChange = session.ofType('route_change').single;
      final timeoutDiagnostic = _diagnostics(session).singleWhere(
        (event) => event.data['cancellationReason'] == 'route_timeout',
      );
      expect(timedOutChange.data['route'], '/picker');
      expect(timedOutChange.data['captureOutcome'], 'timed_out');
      expect(timedOutChange.afterFrame, isNull);
      expect(timeoutDiagnostic.data['outcome'], 'cancelled');
      expect(timeoutDiagnostic.afterFrame, isNull);
      expect(harness.controller.latestFrameId, origin);

      // Resolve the abandoned platform readback before admitting the next route.
      harness.capturer.completeBlocked('late-picker-frame');
      await harness.pumpQueueWork();
      expect(harness.controller.debugCaptureInFlight, isFalse);
      expect(
        session.frames.map((frame) => frame.id),
        isNot(contains('late-picker-frame')),
      );

      final recoveryRoute = harness.controller.route(
        'route_push',
        harness.route('/recovered'),
      );
      await harness.flushScheduler();
      await recoveryRoute;

      final recoveryChange = session.ofType('route_change').last;
      final recoveryDiagnostic = _diagnostics(
        session,
      ).lastWhere((event) => event.data['trigger'] == 'route');
      expect(recoveryChange.data['route'], '/recovered');
      expect(recoveryChange.afterFrame, isNotNull);
      expect(recoveryChange.afterFrame, isNot(origin));
      expect(recoveryDiagnostic.data['outcome'], 'fresh_accepted');
      expect(recoveryDiagnostic.afterFrame, recoveryChange.afterFrame);
      expect(
        harness.provenanceFor(recoveryChange.afterFrame)?.route,
        '/recovered',
      );
      expect(harness.controller.debugRouteCapturePending, isFalse);
      expect(harness.controller.debugCaptureInFlight, isFalse);
      expect(harness.scheduler.pendingDelayCount, 0);
    },
  );

  test(
    'processing failure is explicit and does not prevent fresh recovery',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);
      final session = harness.controller.session!;
      harness.seedRouteState(route: '/start', signature: 'start');
      harness.capturer.failNext = true;

      final failedRoute = harness.controller.route(
        'route_push',
        harness.route('/failed'),
      );
      await harness.flushScheduler();
      await failedRoute;
      final failedChange = session.ofType('route_change').single;
      final failedDiagnostic = _diagnostics(
        session,
      ).singleWhere((event) => event.data['trigger'] == 'route');
      expect(failedDiagnostic.data['outcome'], 'capture_processing_failed');
      expect(failedDiagnostic.afterFrame, isNull);
      expect(failedChange.data['captureFailure'], 'capture_processing_failed');
      expect(failedChange.afterFrame, isNull);

      final recoveredRoute = harness.controller.route(
        'route_push',
        harness.route('/healthy'),
      );
      await harness.flushScheduler();
      await recoveredRoute;
      final recoveredChange = session.ofType('route_change').last;
      expect(recoveredChange.data['route'], '/healthy');
      expect(recoveredChange.afterFrame, isNotNull);
      expect(
        harness.provenanceFor(recoveredChange.afterFrame)?.route,
        '/healthy',
      );
      expect(harness.controller.debugCaptureInFlight, isFalse);
      expect(harness.controller.debugRouteCapturePending, isFalse);
    },
  );
}

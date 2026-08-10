import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

import '../helpers/replay_coherence_harness.dart';

List<TugboatEvent> _diagnostics(TugboatSession session) => session.events
    .where((event) => event.type == 'capture_diagnostic')
    .toList(growable: false);

Map<String, Object?> _data(TugboatEvent event) => event.data;

void main() {
  test(
    'compatible logical captures coalesce but retain per-request evidence',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);
      harness.seedRouteState(route: '/home', signature: 'home');
      final diagnosticStart = _diagnostics(harness.controller.session!).length;

      final first = harness.controller.debugRequestCapture(
        relatedEventId: 'tap-1',
      );
      final second = harness.controller.debugRequestCapture(
        relatedEventId: 'tap-2',
      );
      await harness.pumpMicrotasks();

      final firstResolution = await first.resolution;
      final secondResolution = await second.resolution;
      final diagnostics = _diagnostics(
        harness.controller.session!,
      ).sublist(diagnosticStart);

      expect(diagnostics, hasLength(2));
      expect(
        firstResolution['requestId'],
        isNot(secondResolution['requestId']),
      );
      expect(firstResolution['executionId'], secondResolution['executionId']);
      expect(firstResolution['coalesced'], isTrue);
      expect(secondResolution['coalesced'], isTrue);
      expect(diagnostics.map((event) => _data(event)['requestId']).toSet(), {
        firstResolution['requestId'],
        secondResolution['requestId'],
      });
      expect(diagnostics.map((event) => _data(event)['executionId']).toSet(), {
        firstResolution['executionId'],
      });
      expect(
        diagnostics.every((event) => _data(event)['coalesced'] == true),
        isTrue,
      );
    },
  );

  test(
    'cancelling one coalesced waiter resolves it once without cancelling sibling',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);
      harness.seedRouteState(route: '/home', signature: 'home');
      harness.capturer.blockNext = true;

      final first = harness.controller.debugRequestCapture();
      final second = harness.controller.debugRequestCapture();
      await harness.pumpMicrotasks();
      expect(harness.controller.debugCaptureInFlight, isTrue);

      first.cancel('manual');
      await harness.pumpMicrotasks();
      harness.capturer.completeBlocked();
      await harness.flushScheduler();

      final firstResolution = await first.resolution;
      final secondResolution = await second.resolution;
      final diagnostics = _diagnostics(harness.controller.session!);

      expect(firstResolution['outcome'], 'cancelled');
      expect(firstResolution['cancellationReason'], 'manual');
      expect(secondResolution['outcome'], isNot('cancelled'));
      expect(
        diagnostics.where(
          (event) => _data(event)['requestId'] == firstResolution['requestId'],
        ),
        hasLength(1),
      );
      expect(
        diagnostics.where(
          (event) => _data(event)['requestId'] == secondResolution['requestId'],
        ),
        hasLength(1),
      );
    },
  );

  test(
    'every closed capture outcome emits once and is reflected in health',
    () async {
      const outcomes = <String>[
        'fresh_accepted',
        'exact_content_reused',
        'perceptual_hash_coalesced',
        'screenshot_budget_skip',
        'no_frame_available',
        'no_compatible_frame',
        'paint_readiness_timeout',
        'boundary_unavailable',
        'capture_processing_failed',
        'cancelled',
        'superseded_route_epoch',
      ];
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);
      final compatibleFrame = harness.seedRouteState(
        route: '/home',
        signature: 'home',
      );
      final diagnosticStart = _diagnostics(harness.controller.session!).length;
      final healthStart = harness.controller
          .healthSnapshot()
          .captureDiagnostics;

      for (final outcome in outcomes) {
        harness.controller.debugNextCaptureOutcome = outcome;
        harness.controller.debugNextCaptureFrameId = switch (outcome) {
          'no_frame_available' ||
          'no_compatible_frame' ||
          'paint_readiness_timeout' ||
          'boundary_unavailable' ||
          'capture_processing_failed' ||
          'cancelled' ||
          'superseded_route_epoch' => null,
          _ => compatibleFrame,
        };
        final request = harness.controller.debugRequestCapture(force: true);
        await harness.pumpMicrotasks();
        final resolution = await request.resolution;
        expect(resolution['outcome'], outcome);
      }

      final diagnostics = _diagnostics(
        harness.controller.session!,
      ).sublist(diagnosticStart);
      final health = harness.controller.healthSnapshot().captureDiagnostics;
      expect(diagnostics, hasLength(outcomes.length));
      for (final outcome in outcomes) {
        expect(
          diagnostics.where((event) => _data(event)['outcome'] == outcome),
          hasLength(1),
        );
        expect(
          health.outcomes[outcome],
          (healthStart.outcomes[outcome] ?? 0) + 1,
        );
      }
      expect(health.total, healthStart.total + outcomes.length);
      expect(health.lastOutcome, 'superseded_route_epoch');
    },
  );

  test('cancellation reasons are recorded once per request', () async {
    final cases = <String, Future<void> Function(ReplayCoherenceHarness)>{
      'dispose': (harness) async => harness.controller.dispose(),
      'session_end': (harness) => harness.controller.endSession(),
      'session_replacement': (harness) async =>
          harness.controller.start(const Size(390, 844), 'replacement'),
      'lifecycle_deactivate': (harness) async =>
          harness.controller.recordAppLifecycleState(AppLifecycleState.paused),
      'superseded_route': (harness) async {},
    };

    for (final entry in cases.entries) {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      final session = harness.controller.session!;
      harness.seedRouteState(route: '/home', signature: 'home');
      harness.capturer.blockNext = true;
      final request = harness.controller.debugRequestCapture(force: true);
      await harness.pumpMicrotasks();
      if (entry.key == 'superseded_route') {
        request.cancel(entry.key);
      } else {
        await entry.value(harness);
      }
      final resolution = await request.resolution;
      final diagnostic = _diagnostics(session).singleWhere(
        (event) => _data(event)['requestId'] == resolution['requestId'],
      );

      expect(
        resolution['outcome'],
        entry.key == 'superseded_route'
            ? 'superseded_route_epoch'
            : 'cancelled',
        reason: entry.key,
      );
      expect(resolution['cancellationReason'], entry.key);
      expect(_data(diagnostic)['cancellationReason'], entry.key);
      expect(
        _diagnostics(session).where(
          (event) => _data(event)['requestId'] == resolution['requestId'],
        ),
        hasLength(1),
      );
      if (entry.key != 'dispose') harness.dispose();
    }
  });

  test(
    'diagnostics preserve correlation evidence without raw capture details',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);
      harness.seedRouteState(route: '/settings', signature: 'settings');
      final diagnosticStart = _diagnostics(harness.controller.session!).length;
      final request = harness.controller.debugRequestCapture(
        force: true,
        relatedEventId: 'event-tap-settings',
      );
      await harness.pumpMicrotasks();
      final resolution = await request.resolution;
      final diagnostic = _diagnostics(
        harness.controller.session!,
      ).sublist(diagnosticStart).single;
      final data = _data(diagnostic);

      expect(data['requestId'], resolution['requestId']);
      expect(data['executionId'], resolution['executionId']);
      expect(data['captureSessionId'], harness.controller.session!.id);
      expect(data['routeEpoch'], harness.controller.debugRouteEpoch);
      expect(data, isNot(contains('route')));
      expect(data['trigger'], 'manual');
      expect(data['relatedEventId'], 'event-tap-settings');
      expect(data['visualEvidence'], anyOf('fresh', 'reused', 'unavailable'));
      expect(data['interactionEvidence'], 'linked');
      final encoded = data.toString().toLowerCase();
      expect(encoded, isNot(contains('stack')));
      expect(encoded, isNot(contains('error')));
      expect(encoded, isNot(contains('pixel')));
      expect(encoded, isNot(contains('label')));
      expect(encoded, isNot(contains('/settings')));
    },
  );

  test(
    'health diagnostics are immutable and retain bounded taxonomy counts',
    () async {
      final harness = ReplayCoherenceHarness();
      await harness.setUp();
      addTearDown(harness.dispose);
      harness.seedRouteState(route: '/home', signature: 'home');
      final request = harness.controller.debugRequestCapture();
      await harness.pumpMicrotasks();
      await request.resolution;

      final outcomes = harness.controller
          .healthSnapshot()
          .captureDiagnostics
          .outcomes;
      expect(() => outcomes['tamper'] = 1, throwsUnsupportedError);
      expect(outcomes.keys.length, lessThanOrEqualTo(16));
    },
  );
}

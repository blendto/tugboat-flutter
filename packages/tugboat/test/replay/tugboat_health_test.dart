import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/health.dart';

void main() {
  test('screenshot budget degrades and recovers', () {
    final tracker = TugboatScreenshotBudgetTracker(
      window: const Duration(seconds: 1),
      budgetMicros: 1000,
    );

    tracker.record(
      queueWaitMicros: 0,
      readbackMicros: 800,
      encodeMicros: 800,
      encodedBytes: 10,
    );
    expect(tracker.shouldSkipEligible, isTrue);
    expect(tracker.snapshot().degraded, isTrue);

    tracker.record(
      queueWaitMicros: 0,
      readbackMicros: 0,
      encodeMicros: 0,
      encodedBytes: 0,
      dropReason: 'budget',
    );
    expect(tracker.snapshot().dropped, 1);
    expect(tracker.snapshot().lastDropReason, 'budget');
  });

  test('health snapshot stays sanitized', () {
    final health = TugboatSdkHealth(
      lifecycle: 'active',
      profile: 'productionLean',
      activationRequestId: 'req-1',
      captureSessionId: 'cap-1',
      sinks: const TugboatSinkHealth(pending: 2, accepted: 10, dropped: 1),
      outbox: const TugboatOutboxHealth(
        enabled: true,
        pending: 3,
        bytes: 128,
        quarantined: 0,
      ),
      screenshots: const TugboatScreenshotBudgetHealth(
        degraded: true,
        dropped: 2,
        lastDropReason: 'budget',
      ),
      recentFailures: [
        TugboatSanitizedFailure(
          at: DateTime.utc(2026, 7, 16),
          code: 'sink_timeout',
          component: 'http',
        ),
      ],
    );

    final json = health.toJson();
    final encoded = json.toString();
    expect(encoded.contains('password'), isFalse);
    expect(encoded.contains('pixel'), isFalse);
    expect(json['activationRequestId'], 'req-1');
    expect(json['captureSessionId'], 'cap-1');
    expect((json['recentFailures'] as List).single['code'], 'sink_timeout');
  });
}

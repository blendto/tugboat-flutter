import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tugboat/src/capture_sink.dart';
import 'package:tugboat/src/collector_config.dart';
import 'package:tugboat/src/collector_http_sink.dart';
import 'package:tugboat/src/models.dart';
import 'package:tugboat/src/sink_ledger.dart';

/// Health must not reset to zero when an activation ends: a deactivated
/// controller's sink may still be draining, and what it discards is loss.
void main() {
  final config = TugboatCollectorConfig(
    baseUrl: 'http://127.0.0.1:0',
    apiKey: 'pmk_test',
    eventBatchSize: 10,
    eventFlushInterval: const Duration(hours: 1),
    appInfo: const TugboatCollectorAppInfo(
      name: 'Example App',
      version: '1.0.0',
      buildNumber: '1',
      installationId: 'inst_1',
      appId: 'com.example.app',
    ),
    deviceInfo: const TugboatCollectorDeviceInfo(
      id: 'device_client',
      platform: 'ios',
      screenSize: TugboatCollectorScreenSize(width: 390, height: 844),
      screenDensity: 3,
      screenDpi: 460,
      screenPixelDensity: 3,
    ),
    ipInfo: const TugboatCollectorIpInfo(ip: '127.0.0.1'),
    locale: const TugboatCollectorLocaleInfo(language: 'en'),
  );

  TugboatSession session(String id) => TugboatSession(
    id: id,
    startedAt: DateTime.utc(2026, 6, 19),
    platform: 'ios',
    viewport: const TugboatRect(0, 0, 390, 844),
  );

  TugboatEvent event(int index) => TugboatEvent(
    id: 'event-$index',
    atMs: index,
    type: 'capture_diagnostic',
    data: {'index': index},
  );

  Future<void> waitFor(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 1));
    while (!condition() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// A hub whose event posts wait on [stalled]; the session post succeeds.
  ({TugboatCaptureSinkHub hub, CollectorHttpSink sink, int Function() posts})
  stalledHub(Completer<http.Response> stalled) {
    var eventPosts = 0;
    final sink = CollectorHttpSink(
      config: config,
      client: MockClient((request) async {
        if (request.url.path == '/v1/sessions') {
          return http.Response(jsonEncode({'sessionId': 'sess_server'}), 202);
        }
        eventPosts += 1;
        return stalled.future;
      }),
    );
    return (
      hub: TugboatCaptureSinkHub([sink]),
      sink: sink,
      posts: () => eventPosts,
    );
  }

  final ledger = TugboatSinkLedger.instance;
  setUp(ledger.resetForTest);
  tearDown(ledger.resetForTest);

  Future<TugboatCaptureSinkHub> retireWithBacklog(
    Completer<http.Response> stalled,
  ) async {
    final first = stalledHub(stalled);
    first.hub.startSession(session('session-1'));
    await first.sink.flush();
    // 10 go out in a request that stalls; 3 stay queued.
    for (var i = 0; i < 13; i++) {
      first.hub.recordEvent(event(i));
    }
    await waitFor(() => first.posts() > 0);
    expect(ledger.snapshot(first.hub).pending, 13);

    // As the controller does: dispose once session_end is sent, and keep
    // counting the hub from the moment it is let go.
    final disposed = Future<void>(first.hub.dispose);
    ledger.retire(first.hub, disposed);
    await disposed;
    await Future<void>.delayed(Duration.zero);
    return first.hub;
  }

  for (final (status, inFlightDropped) in [(202, 0), (503, 10)]) {
    test('a retired hub keeps counting until it settles '
        '(stalled request answered $status)', () async {
      final stalled = Completer<http.Response>();
      final retired = await retireWithBacklog(stalled);

      final current = TugboatCaptureSinkHub(const []);
      final whileDraining = ledger.snapshot(current);
      expect(whileDraining.accepted, 13);
      expect(whileDraining.dropped, 3, reason: 'queued backlog discarded');
      expect(whileDraining.pending, 10, reason: 'request still open');

      stalled.complete(http.Response('{}', status));
      await waitFor(() => retired.pendingCount == 0);

      final settled = ledger.snapshot(current);
      expect(settled.pending, 0);
      expect(settled.accepted, 13);
      expect(settled.dropped, 3 + inFlightDropped);
      // Folded into the settled totals: still counted once.
      expect(ledger.snapshot(current).dropped, 3 + inFlightDropped);
    });
  }

  test('the next activation adds to the totals instead of resetting', () async {
    final stalled = Completer<http.Response>();
    await retireWithBacklog(stalled);
    stalled.complete(http.Response('{}', 503));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final next = stalledHub(Completer<http.Response>());
    next.hub.startSession(session('session-2'));
    await next.sink.flush();
    next.hub.recordEvent(event(100));

    final health = ledger.snapshot(next.hub);
    expect(health.accepted, 14);
    expect(health.dropped, 13);
    expect(health.pending, 1);
    next.sink.dispose();
  });

  test('resetForTest clears every total', () async {
    final stalled = Completer<http.Response>();
    await retireWithBacklog(stalled);
    ledger.resetForTest();
    final health = ledger.snapshot(null);
    expect(health.pending, 0);
    expect(health.accepted, 0);
    expect(health.dropped, 0);
    stalled.complete(http.Response('{}', 202));
  });
}

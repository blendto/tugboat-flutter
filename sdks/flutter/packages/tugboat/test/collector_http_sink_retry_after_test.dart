import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tugboat/src/collector_config.dart';
import 'package:tugboat/src/collector_http_sink.dart';
import 'package:tugboat/src/collector_lane_delays.dart';
import 'package:tugboat/src/models.dart';

void main() {
  test('events lane does not retry before Retry-After timer fires', () async {
    var now = DateTime.utc(2026, 1, 1);
    var batchAttempts = 0;
    final pendingTimers = <void Function()>[];
    final client = _SequenceClient(
      onBatch: () {
        batchAttempts++;
        if (batchAttempts == 1) {
          return http.StreamedResponse(
            Stream.value(utf8.encode('{}')),
            429,
            headers: const {'retry-after': '1'},
          );
        }
        return http.StreamedResponse(Stream.value(utf8.encode('{}')), 202);
      },
    );
    final sink = _sink(
      client,
      () => now,
      scheduleTimer: _queueTimer(pendingTimers),
    );
    _startWithEvent(sink, now);
    await sink.flush();
    expect(batchAttempts, 1);

    now = now.add(const Duration(milliseconds: 500));
    await sink.flush();
    expect(batchAttempts, 1);

    expect(pendingTimers, isNotEmpty);
    pendingTimers.removeLast()();
    await sink.flush();
    expect(batchAttempts, 2);
    sink.dispose();
  });

  test('frames lane keeps sending while events lane waits', () async {
    var now = DateTime.utc(2026, 1, 1);
    var batchAttempts = 0;
    var frameAttempts = 0;
    final pendingTimers = <void Function()>[];
    final client = _RoutingClient(
      onBatch: () {
        batchAttempts++;
        if (batchAttempts == 1) {
          return http.StreamedResponse(
            Stream.value(utf8.encode('{}')),
            429,
            headers: const {'retry-after': '2'},
          );
        }
        return http.StreamedResponse(Stream.value(utf8.encode('{}')), 202);
      },
      onFrame: () {
        frameAttempts++;
        return http.StreamedResponse(Stream.value(utf8.encode('{}')), 202);
      },
    );
    final sink = _sink(
      client,
      () => now,
      scheduleTimer: _queueTimer(pendingTimers),
    );
    _startWithEvent(sink, now);
    sink.recordFrame(
      const TugboatFrame(
        id: 'frame-0',
        atMs: 0,
        width: 10,
        height: 10,
        contentHash: 'h0',
      ),
      Uint8List.fromList([1, 2, 3]),
      sessionId: 's1',
    );
    await sink.flush();
    expect(batchAttempts, 1);
    expect(frameAttempts, 1);

    await sink.flush();
    expect(batchAttempts, 1);
    expect(frameAttempts, 1);

    pendingTimers.removeLast()();
    await sink.flush();
    expect(batchAttempts, 2);
    sink.dispose();
  });

  test('endSession queues session_end without waiting on events delay', () async {
    var now = DateTime.utc(2026, 1, 1);
    final lifecycleTypes = <String>[];
    final client = _LifecycleTapClient(
      onLifecycle: (body) {
        lifecycleTypes.add(
          (jsonDecode(body) as Map<String, dynamic>)['eventType'] as String,
        );
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"sessionId":"srv"}')),
          202,
        );
      },
      onBatch: () => http.StreamedResponse(
        Stream.value(utf8.encode('{}')),
        429,
        headers: const {'retry-after': '60'},
      ),
    );
    final sink = _sink(client, () => now);
    _startWithEvent(sink, now);
    await sink.flush();

    await sink.endSession();
    expect(lifecycleTypes, contains('session_end'));
    sink.dispose();
  });

  test('startSession cancels a prior session Retry-After wait', () async {
    var now = DateTime.utc(2026, 1, 1);
    var batchAttempts = 0;
    final pendingTimers = <void Function()>[];
    final client = _SequenceClient(
      onBatch: () {
        batchAttempts++;
        if (batchAttempts == 1) {
          return http.StreamedResponse(
            Stream.value(utf8.encode('{}')),
            429,
            headers: const {'retry-after': '30'},
          );
        }
        return http.StreamedResponse(Stream.value(utf8.encode('{}')), 202);
      },
    );
    final sink = _sink(
      client,
      () => now,
      scheduleTimer: _queueTimer(pendingTimers),
    );
    _startWithEvent(sink, now);
    await sink.flush();
    expect(batchAttempts, 1);
    expect(pendingTimers, isNotEmpty);

    sink.startSession(
      TugboatSession(
        id: 's2',
        startedAt: now,
        viewport: const TugboatRect(0, 0, 100, 100),
        platform: 'test',
      ),
    );
    sink.recordEvent(
      const TugboatEvent(
        id: 'e2',
        atMs: 0,
        type: 'interaction',
        stream: TugboatEventStream.semantic,
        data: {'interactionSchema': 2, 'gesture': 'tap'},
      ),
    );
    await sink.flush();
    expect(pendingTimers, isEmpty);
    expect(batchAttempts, greaterThan(1));
    sink.dispose();
  });
}

CollectorLaneTimerSchedule _queueTimer(List<void Function()> pending) {
  return (Duration wait, void Function() onFire) {
    pending.add(onFire);
    return () {
      pending.remove(onFire);
    };
  };
}

CollectorHttpSink _sink(
  http.Client client,
  DateTime Function() now, {
  CollectorLaneTimerSchedule? scheduleTimer,
}) {
  return CollectorHttpSink(
    config: _config,
    client: client,
    debugNow: now,
    debugScheduleLaneTimer: scheduleTimer,
  );
}

void _startWithEvent(CollectorHttpSink sink, DateTime now) {
  sink.startSession(
    TugboatSession(
      id: 's1',
      startedAt: now,
      viewport: const TugboatRect(0, 0, 100, 100),
      platform: 'test',
    ),
  );
  sink.recordEvent(
    const TugboatEvent(
      id: 'e1',
      atMs: 0,
      type: 'interaction',
      stream: TugboatEventStream.semantic,
      data: {'interactionSchema': 2, 'gesture': 'tap'},
    ),
  );
}

final _config = TugboatCollectorConfig(
  baseUrl: 'http://example.invalid',
  apiKey: 'pmk_test',
  appInfo: const TugboatCollectorAppInfo(
    name: 'App',
    version: '1',
    buildNumber: '1',
    installationId: 'i',
    appId: 'com.example',
  ),
  deviceInfo: const TugboatCollectorDeviceInfo(
    id: 'd',
    platform: 'ios',
    screenSize: TugboatCollectorScreenSize(width: 100, height: 100),
    screenDensity: 1,
    screenDpi: 160,
    screenPixelDensity: 1,
  ),
  ipInfo: const TugboatCollectorIpInfo(ip: '127.0.0.1'),
  locale: const TugboatCollectorLocaleInfo(language: 'en'),
);

class _SequenceClient extends http.BaseClient {
  _SequenceClient({required this.onBatch});

  final http.StreamedResponse Function() onBatch;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path == '/v1/sessions') {
      return http.StreamedResponse(
        Stream.value(utf8.encode('{"sessionId":"srv"}')),
        202,
      );
    }
    return onBatch();
  }
}

class _RoutingClient extends http.BaseClient {
  _RoutingClient({required this.onBatch, required this.onFrame});

  final http.StreamedResponse Function() onBatch;
  final http.StreamedResponse Function() onFrame;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path == '/v1/sessions') {
      return http.StreamedResponse(
        Stream.value(utf8.encode('{"sessionId":"srv"}')),
        202,
      );
    }
    if (request.url.path == '/v1/frames') return onFrame();
    return onBatch();
  }
}

class _LifecycleTapClient extends http.BaseClient {
  _LifecycleTapClient({required this.onLifecycle, required this.onBatch});

  final http.StreamedResponse Function(String body) onLifecycle;
  final http.StreamedResponse Function() onBatch;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path == '/v1/sessions') {
      final body = await request.finalize().bytesToString();
      return onLifecycle(body);
    }
    return onBatch();
  }
}

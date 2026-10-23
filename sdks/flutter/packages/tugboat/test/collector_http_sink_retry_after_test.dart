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
  test('collector config defaults to 60 s and 10 s Retry-After caps', () {
    expect(_config().retryAfterCap, const Duration(seconds: 60));
    expect(_config().endingRetryAfterCap, const Duration(seconds: 10));
  });

  test('events lane does not retry before Retry-After timer fires', () async {
    final h = _Harness(
      (call, h) => call.isBatch && h.client.batches.length == 1
          ? _response(429, retryAfter: '1')
          : _accepted(),
    );
    h.start();
    h.recordEvent('e1');
    await h.sink.flush();
    expect(h.client.batches, hasLength(1));
    expect(h.timers.waits, [const Duration(seconds: 1)]);

    h.clock.advance(const Duration(milliseconds: 500));
    await h.sink.flush();
    expect(h.client.batches, hasLength(1));

    h.timers.fireLast();
    await _settle();
    expect(h.client.batches, hasLength(2));
    h.sink.dispose();
  });

  test('a wall-clock jump does not end a Retry-After wait early', () async {
    final h = _Harness(
      (call, h) => call.isBatch && h.client.batches.length == 1
          ? _response(429, retryAfter: '30')
          : _accepted(),
    );
    h.start();
    h.recordEvent('e1');
    await h.sink.flush();
    h.clock.wall = h.clock.wall.add(const Duration(hours: 1));
    await h.sink.flush();
    expect(h.client.batches, hasLength(1));
    h.sink.dispose();
  });

  test('frames lane keeps sending while events lane waits', () async {
    final h = _Harness(
      (call, h) => call.isBatch && h.client.batches.length == 1
          ? _response(429, retryAfter: '2')
          : _accepted(),
    );
    h.start();
    h.recordEvent('e1');
    h.recordFrame(0);
    await h.sink.flush();
    expect(h.client.batches, hasLength(1));
    expect(h.client.frames, hasLength(1));

    h.recordFrame(1);
    await h.sink.flush();
    expect(h.client.batches, hasLength(1));
    expect(h.client.frames, hasLength(2));

    h.timers.fireLast();
    await _settle();
    expect(h.client.batches, hasLength(2));
    h.sink.dispose();
  });

  test(
    'endSession queues session_end without waiting on events delay',
    () async {
      final h = _Harness(
        (call, h) =>
            call.isBatch ? _response(429, retryAfter: '60') : _accepted(),
      );
      h.start();
      h.recordEvent('e1');
      await h.sink.flush();

      await h.sink.endSession();
      expect(h.client.lifecycleTypes, ['session_start', 'session_end']);
      h.sink.dispose();
    },
  );

  test('startSession cancels a prior session Retry-After wait', () async {
    final h = _Harness(
      (call, h) => call.isBatch && h.client.batches.length == 1
          ? _response(429, retryAfter: '30')
          : _accepted(),
    );
    h.start();
    h.recordEvent('e1');
    await h.sink.flush();
    expect(h.client.batches, hasLength(1));
    expect(h.timers.pending, hasLength(1));

    h.start(id: 's2');
    h.recordEvent('e2');
    await h.sink.flush();
    expect(h.timers.pending, isEmpty);
    expect(h.client.batches, hasLength(2));
    h.sink.dispose();
  });

  test('lifecycle lane delay does not block events or frames', () async {
    final h = _Harness(
      (call, h) => call.isLifecycle && call.eventType == 'user_changed'
          ? (h.client.lifecycleTypes.length == 2
                ? _response(429, retryAfter: '60')
                : _accepted())
          : _accepted(),
      identityDebounce: Duration.zero,
    );
    h.start();
    await h.sink.flush();
    unawaited(h.sink.setUserId('user-2'));
    await _settle();
    expect(h.client.lifecycleTypes, ['session_start', 'user_changed']);
    expect(h.timers.waits, [const Duration(seconds: 60)]);

    // After the 429: events go out, and no /v1/sessions with them.
    h.recordEvent('after-429');
    await h.sink.flush();
    expect(h.client.batchEventNames, [
      ['after-429'],
    ]);
    expect(h.client.lifecycleTypes, hasLength(2));

    // A tap's frame goes out too.
    h.recordFrame(6);
    await h.sink.flush();
    expect(h.client.frames, hasLength(1));
    expect(h.client.lifecycleTypes, hasLength(2));

    // A flush just before the deadline sends no lifecycle post.
    h.clock.advance(const Duration(seconds: 59));
    await h.sink.flush();
    expect(h.client.lifecycleTypes, hasLength(2));

    // The lane timer sends the waiting user_changed.
    h.clock.advance(const Duration(seconds: 1));
    h.timers.fireLast();
    await _settle();
    expect(h.client.lifecycleTypes, [
      'session_start',
      'user_changed',
      'user_changed',
    ]);
    h.sink.dispose();
  });

  test(
    'a wait armed mid-pass keeps later fresh events pending, unsent',
    () async {
      final h = _Harness(
        (call, h) => call.isBatch && h.client.batches.length == 1
            ? _response(429, retryAfter: '30')
            : _accepted(),
        config: _config(maxPendingBatches: 1),
      );
      h.start();
      await h.sink.flush();
      for (var i = 0; i < 11; i++) {
        h.recordEvent('e$i');
      }
      await _settle();
      await h.sink.flush();
      // One request: the first batch, answered 429 + Retry-After.
      expect(h.client.batchEventNames, [
        [for (var i = 0; i < 10; i++) 'e$i'],
      ]);

      h.timers.fireLast();
      await _settle();
      // The answered batch is the only retry batch (nothing evicted under
      // maxPendingBatches 1): it goes first, then the event left pending.
      expect(h.client.batchEventNames.skip(1).toList(), [
        [for (var i = 0; i < 10; i++) 'e$i'],
        ['e10'],
      ]);
      h.sink.dispose();
    },
  );

  test(
    'lifecycle wait during endSession is capped, then drains session_end',
    () async {
      final h = _Harness(
        (call, h) => call.isLifecycle && h.client.lifecycleTypes.length == 1
            ? _response(429, retryAfter: '60')
            : _accepted(),
      );
      h.start();
      h.recordEvent('e1');
      await h.sink.flush();
      expect(h.timers.waits, [const Duration(seconds: 60)]);

      await h.sink.endSession();
      // The ending cap shortens the running 60 s wait to 10 s, and
      // session_end queues behind the waiting session_start.
      expect(h.timers.waits.last, const Duration(seconds: 10));
      expect(h.client.lifecycleTypes, ['session_start']);

      h.clock.advance(const Duration(seconds: 10));
      h.timers.fireLast();
      await _settle();
      expect(h.client.lifecycleTypes, [
        'session_start',
        'session_start',
        'session_end',
      ]);
      h.sink.dispose();
    },
  );

  test('a lifecycle 429 received while ending waits at most 10 s', () async {
    final h = _Harness((call, h) {
      if (!call.isLifecycle) return _accepted();
      return switch (h.client.lifecycleTypes.length) {
        1 => _response(503),
        2 => _response(429, retryAfter: '60'),
        _ => _accepted(),
      };
    });
    h.start();
    await h.sink.flush();
    expect(h.timers.waits, isEmpty);

    await h.sink.endSession();
    expect(h.client.lifecycleTypes, ['session_start', 'session_start']);
    expect(h.timers.waits, [const Duration(seconds: 10)]);

    h.timers.fireLast();
    await _settle();
    expect(h.client.lifecycleTypes.skip(2), ['session_start', 'session_end']);
    h.sink.dispose();
  });

  test('a frame upload answered after startSession arms nothing', () async {
    final h = _Harness(
      (call, h) =>
          call.isFrame && h.client.frames.length == 1 ? null : _accepted(),
    );
    h.start();
    await h.sink.flush();
    h.recordFrame(0);
    await _settle();
    expect(h.client.frames, hasLength(1));

    h.start(id: 's2');
    h.client.frames.single.answer(_response(429, retryAfter: '60'));
    await _settle();
    await h.sink.flush();
    h.recordFrame(0, sessionId: 's2');
    await h.sink.flush();
    expect(h.timers.waits, isEmpty);
    expect(h.client.frames, hasLength(2));
    h.sink.dispose();
  });

  test(
    'a lifecycle response answered after startSession arms nothing',
    () async {
      final h = _Harness(
        (call, h) => call.isLifecycle && h.client.lifecycleTypes.length == 1
            ? null
            : _accepted(),
      );
      h.start();
      await _settle();
      expect(h.client.lifecycleTypes, ['session_start']);

      h.start(id: 's2');
      h.client.lifecycle.single.answer(_response(429, retryAfter: '60'));
      await _settle();
      await h.sink.flush();
      expect(h.timers.waits, isEmpty);
      expect(h.client.lifecycleTypes, ['session_start', 'session_start']);
      h.sink.dispose();
    },
  );

  test('an events response answered after startSession arms nothing', () async {
    final h = _Harness(
      (call, h) =>
          call.isBatch && h.client.batches.length == 1 ? null : _accepted(),
    );
    h.start();
    await h.sink.flush();
    h.recordEvent('e1');
    unawaited(h.sink.flush());
    await _settle();
    expect(h.client.batches, hasLength(1));

    h.start(id: 's2');
    h.client.batches.single.answer(_response(429, retryAfter: '60'));
    await _settle();
    await h.sink.flush();
    h.recordEvent('e2');
    await h.sink.flush();
    expect(h.timers.waits, isEmpty);
    expect(h.client.batchEventNames.last, ['e2']);
    h.sink.dispose();
  });

  test('startSession during endSession keeps the new session alive', () async {
    final h = _Harness((call, h) => _accepted());
    h.start();
    await h.sink.flush();

    final ending = h.sink.endSession();
    h.start(id: 's2');
    await ending;
    await h.sink.flush();
    expect(h.client.lifecycleTypes, ['session_start', 'session_start']);
    h.sink.dispose();
  });

  test('Retry-After caps are clamped and never throw', () async {
    final huge = _Harness(
      (call, h) => call.isLifecycle && h.client.lifecycleTypes.length == 1
          ? _response(429, retryAfter: '999999999999')
          : _accepted(),
      config: _config(
        retryAfterCap: const Duration(days: 100000000),
        endingRetryAfterCap: const Duration(days: 100000000),
      ),
    );
    huge.start();
    await huge.sink.flush();
    expect(huge.timers.waits, [collectorRetryAfterCapLimit]);
    await huge.sink.endSession();
    expect(huge.timers.waits.last, collectorRetryAfterCapLimit);
    huge.sink.dispose();

    final none = _Harness(
      (call, h) => call.isLifecycle && h.client.lifecycleTypes.length == 1
          ? _response(429, retryAfter: '60')
          : _accepted(),
      config: _config(
        retryAfterCap: const Duration(seconds: -5),
        endingRetryAfterCap: Duration.zero,
      ),
    );
    none.start();
    await none.sink.flush();
    // A zero (or negative) cap honours no hint: no wait, the next flush
    // retries.
    expect(none.timers.waits, isEmpty);
    await none.sink.flush();
    expect(none.client.lifecycleTypes, ['session_start', 'session_start']);
    none.sink.dispose();
  });
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

http.StreamedResponse _accepted() =>
    _response(202, body: '{"sessionId":"srv"}');

http.StreamedResponse _response(
  int status, {
  String body = '{}',
  String? retryAfter,
}) => http.StreamedResponse(
  Stream.value(utf8.encode(body)),
  status,
  headers: {if (retryAfter != null) 'retry-after': retryAfter},
);

/// Both sink clocks: wall (`debugNow`) and monotonic (`debugElapsed`).
class _Clock {
  DateTime wall = DateTime.utc(2026, 1, 1);
  Duration elapsed = Duration.zero;

  void advance(Duration by) {
    wall = wall.add(by);
    elapsed += by;
  }
}

/// The lane timer seam: records each scheduled wait; tests fire them.
class _LaneTimers {
  final List<Duration> waits = [];
  final List<void Function()> pending = [];

  void Function() schedule(Duration wait, void Function() onFire) {
    waits.add(wait);
    pending.add(onFire);
    return () => pending.remove(onFire);
  }

  void fireLast() => pending.removeLast()();
}

typedef _Respond =
    http.StreamedResponse? Function(_Call call, _Harness harness);

class _Harness {
  _Harness(
    _Respond respond, {
    TugboatCollectorConfig? config,
    Duration identityDebounce = const Duration(seconds: 3),
  }) {
    client = _ScriptedClient((call) => respond(call, this));
    sink = CollectorHttpSink(
      config: config ?? _config(),
      client: client,
      debugNow: () => clock.wall,
      debugElapsed: () => clock.elapsed,
      debugScheduleLaneTimer: timers.schedule,
      identityDebounceDuration: identityDebounce,
    );
  }

  final clock = _Clock();
  final timers = _LaneTimers();
  late final _ScriptedClient client;
  late final CollectorHttpSink sink;
  String _sessionId = 's1';
  int _event = 0;

  void start({String id = 's1'}) {
    _sessionId = id;
    sink.startSession(
      TugboatSession(
        id: id,
        startedAt: clock.wall,
        viewport: const TugboatRect(0, 0, 100, 100),
        platform: 'test',
      ),
    );
  }

  void recordEvent(String name) {
    sink.recordEvent(
      TugboatEvent(
        id: 'event-${_event++}',
        atMs: 0,
        type: 'external_event',
        stream: TugboatEventStream.evidence,
        data: {'name': name},
      ),
    );
  }

  void recordFrame(int frameNo, {String? sessionId}) {
    sink.recordFrame(
      TugboatFrame(
        id: 'frame-$frameNo',
        atMs: frameNo,
        width: 10,
        height: 10,
        contentHash: 'h$frameNo',
      ),
      Uint8List.fromList([frameNo]),
      sessionId: sessionId ?? _sessionId,
    );
  }
}

/// One request the sink sent. [answer] completes a deferred one.
class _Call {
  _Call(this.path, this.body);

  final String path;
  final String body;
  final Completer<http.StreamedResponse> _response = Completer();

  bool get isLifecycle => path == '/v1/sessions';
  bool get isBatch => path == '/v1/events/batch';
  bool get isFrame => path == '/v1/frames';

  String? get eventType => isLifecycle
      ? (jsonDecode(body) as Map<String, dynamic>)['eventType'] as String?
      : null;

  void answer(http.StreamedResponse response) => _response.complete(response);
}

/// Answers each request with `respond(call)`; null defers it until the test
/// calls [_Call.answer].
class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this._respond);

  final http.StreamedResponse? Function(_Call call) _respond;
  final List<_Call> calls = [];

  List<_Call> get lifecycle => calls.where((c) => c.isLifecycle).toList();
  List<_Call> get batches => calls.where((c) => c.isBatch).toList();
  List<_Call> get frames => calls.where((c) => c.isFrame).toList();

  List<String> get lifecycleTypes => [
    for (final call in lifecycle) call.eventType ?? '',
  ];

  List<List<String>> get batchEventNames => [
    for (final call in batches)
      [
        for (final event
            in (jsonDecode(call.body) as Map<String, dynamic>)['events']
                as List<dynamic>)
          ((event as Map<String, dynamic>)['payload'] as Map)['name'] as String,
      ],
  ];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request is http.Request ? request.body : '';
    final call = _Call(request.url.path, body);
    calls.add(call);
    final response = _respond(call);
    if (response != null) return response;
    return call._response.future;
  }
}

TugboatCollectorConfig _config({
  int maxPendingBatches = 20,
  Duration retryAfterCap = const Duration(seconds: 60),
  Duration endingRetryAfterCap = const Duration(seconds: 10),
}) => TugboatCollectorConfig(
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
  maxPendingBatches: maxPendingBatches,
  retryAfterCap: retryAfterCap,
  endingRetryAfterCap: endingRetryAfterCap,
);

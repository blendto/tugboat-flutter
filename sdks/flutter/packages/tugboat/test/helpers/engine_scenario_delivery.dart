// The collector-delivery half of the Dart `engine.scenario` runner
// (engine_scenario.dart): a deterministic scheduler, a fake HTTP client that
// turns `CollectorHttpSink` requests into engine `http.send` effects and
// scenario `transport.result` steps into responses, and the mapping from the
// engine's `collector` configuration onto `TugboatCollectorConfig`.
//
// How delivery maps onto Dart:
// - Scenario time drives fake time: before each step the scheduler advances
//   to the step's `at.monoUs`, firing every Dart timer that is due (the
//   periodic flush, the identity debounce, the frame upload timeout, the
//   widget's background flush) and running microtasks after each. A
//   `timer.fired` step therefore needs no Dart call: the matching Dart timer
//   fires as time reaches it. The sink's wall clock is the scheduler's time
//   plus the scenario's (constant) wall-minus-mono offset.
// - Each request the sink sends becomes one `http.send` effect with a
//   runner-minted `http-N` id in send order (the engine mints the same ids,
//   one request in flight at a time). JSON bodies are compared byte for byte
//   (`jsonBody`); multipart uploads by their ordered fields and their files'
//   handles and filenames (a frame's bytes are its handle's UTF-8).
// - Only `http.send` effects are compared. `timer.schedule`/`timer.cancel`
//   have no Dart counterpart (Dart owns its timers), and `frame.release` has
//   none either (Dart keeps bytes until garbage collection).
// - `timeoutMs` is compared on frame uploads (Dart's fixed 15 s) but not on
//   JSON posts: Dart puts no timeout on them (change C3).
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:tugboat/src/capture_sink.dart';
import 'package:tugboat/src/collector_config.dart';
import 'package:tugboat/src/collector_http_sink.dart';
import 'package:tugboat/src/models.dart';

/// Deterministic time for one scenario. Microtasks and timers created in
/// [run] execute only when the runner advances time.
class ScenarioScheduler {
  int nowUs = 0;
  final Queue<void Function()> _microtasks = Queue();
  final List<_ScenarioTimer> _timers = [];
  int _sequence = 0;

  T run<T>(T Function() body) => runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      scheduleMicrotask: (self, parent, zone, task) => _microtasks.add(task),
      createTimer: (self, parent, zone, duration, callback) =>
          _add(duration, (_) => callback(), periodic: false),
      createPeriodicTimer: (self, parent, zone, period, callback) =>
          _add(period, callback, periodic: true),
    ),
  );

  Timer _add(
    Duration duration,
    void Function(Timer) callback, {
    required bool periodic,
  }) {
    final timer = _ScenarioTimer(
      deadlineUs: nowUs + duration.inMicroseconds,
      periodUs: duration.inMicroseconds,
      periodic: periodic,
      sequence: _sequence++,
      callback: callback,
    );
    _timers.add(timer);
    return timer;
  }

  void flushMicrotasks() {
    while (_microtasks.isNotEmpty) {
      _microtasks.removeFirst()();
    }
  }

  /// Fires every timer due by [targetUs] in deadline order (creation order
  /// on ties), running microtasks after each, then sets the time.
  void advanceTo(int targetUs) {
    flushMicrotasks();
    for (
      var next = _nextDue(targetUs);
      next != null;
      next = _nextDue(targetUs)
    ) {
      if (next.deadlineUs > nowUs) nowUs = next.deadlineUs;
      next.fire();
      flushMicrotasks();
    }
    if (targetUs > nowUs) nowUs = targetUs;
  }

  _ScenarioTimer? _nextDue(int targetUs) {
    _timers.removeWhere((timer) => !timer.isActive);
    _ScenarioTimer? next;
    for (final timer in _timers) {
      if (timer.deadlineUs > targetUs) continue;
      if (next == null ||
          timer.deadlineUs < next.deadlineUs ||
          (timer.deadlineUs == next.deadlineUs &&
              timer.sequence < next.sequence)) {
        next = timer;
      }
    }
    return next;
  }
}

class _ScenarioTimer implements Timer {
  _ScenarioTimer({
    required this.deadlineUs,
    required this.periodUs,
    required this.periodic,
    required this.sequence,
    required this.callback,
  });

  int deadlineUs;
  final int periodUs;
  final bool periodic;
  int sequence;
  final void Function(Timer) callback;
  bool _active = true;
  int _tick = 0;

  void fire() {
    if (periodic) {
      _tick += 1;
      deadlineUs += periodUs;
    } else {
      _active = false;
    }
    callback(this);
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  @override
  void cancel() => _active = false;
}

/// The collector endpoint the sink talks to: records each request as an
/// `http.send` effect and answers it when a `transport.result` step names it.
class ScenarioCollectorClient extends http.BaseClient {
  ScenarioCollectorClient(this._handleOf);

  final String Function(Uint8List bytes) _handleOf;
  final List<Map<String, Object?>> effects = [];
  final Map<String, Completer<http.StreamedResponse>> _pending = {};
  int _nextRequest = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await _bodyOf(request);
    final requestId = 'http-${_nextRequest++}';
    final path = request.url.path;
    effects.add({
      'type': 'http.send',
      'requestId': requestId,
      'lane': _lanes[path] ?? 'unknown',
      'path': path,
      if (path == '/v1/frames') 'timeoutMs': 15000,
      ...body,
    });
    final response = Completer<http.StreamedResponse>();
    _pending[requestId] = response;
    return response.future;
  }

  Future<Map<String, Object?>> _bodyOf(http.BaseRequest request) async {
    if (request is http.Request) return {'jsonBody': request.body};
    final multipart = request as http.MultipartRequest;
    return {
      'multipart': {
        'fields': [
          for (final field in multipart.fields.entries)
            [field.key, field.value],
        ],
        'frames': [
          for (final file in multipart.files)
            {
              'handle': _handleOf(await file.finalize().toBytes()),
              'filename': file.filename,
            },
        ],
      },
    };
  }

  /// Answers the request [input] names (`transport.result`). Unknown and
  /// answered ids are ignored, as the engine ignores them.
  void answer(Map<String, Object?> input) {
    final response = _pending.remove(input['requestId']);
    if (response == null) return;
    switch (input['outcome']) {
      case 'http':
        final body = utf8.encode((input['body'] ?? '') as String);
        final headers = <String, String>{};
        final retryAfter = input['retryAfter'];
        if (retryAfter is String && retryAfter.isNotEmpty) {
          headers['retry-after'] = retryAfter;
        }
        response.complete(
          http.StreamedResponse(
            Stream.value(body),
            input['status']! as int,
            headers: headers,
          ),
        );
      case 'timeout':
        response.completeError(TimeoutException('scenario timeout'));
      default:
        response.completeError(http.ClientException('scenario error'));
    }
  }

  static const _lanes = {
    '/v1/sessions': 'lifecycle',
    '/v1/events/batch': 'events',
    '/v1/frames': 'frames',
  };
}

/// The real [CollectorHttpSink] behind a scenario, fed the way the
/// controller's sink hub and the `TugboatReplay` widget feed it.
class ScenarioDelivery {
  ScenarioDelivery({
    required ScenarioCollector collector,
    required this.scheduler,
    required DateTime Function() now,
  }) : enabled = collector.enabled,
       client = ScenarioCollectorClient(handleOfBytes) {
    sink = CollectorHttpSink(
      config: collector.config,
      client: client,
      identityDebounceDuration: collector.identityDebounce,
      debugNow: now,
      debugElapsed: () => Duration(microseconds: scheduler.nowUs),
    );
  }

  final bool enabled;
  final ScenarioScheduler scheduler;
  final ScenarioCollectorClient client;
  late final CollectorHttpSink sink;
  final List<TugboatCaptureEnvelope> _forwards = [];
  Timer? _backgroundFlush;

  /// What the hub delivered while a controller call ran; forwarded to the
  /// sink once the call returns ([drain]), still in publish order.
  void forward(TugboatCaptureEnvelope envelope) {
    if (enabled) _forwards.add(envelope);
  }

  /// The hub starts sinks before `session_start` is published.
  void start(TugboatSession session) {
    if (enabled) sink.startSession(session);
  }

  void drain() {
    final forwards = List.of(_forwards);
    _forwards.clear();
    for (final envelope in forwards) {
      final event = envelope.event;
      final frame = envelope.frame;
      if (event != null) sink.recordEvent(event);
      if (frame != null) {
        sink.recordFrame(
          frame,
          envelope.frameBytes!,
          sessionId: envelope.captureSessionId,
        );
      }
    }
  }

  void end() {
    if (enabled) unawaited(sink.endSession());
  }

  /// `TugboatReplay`'s lifecycle handling: paused and hidden schedule a
  /// flush 500 ms later; resumed and detached cancel it.
  void appLifecycle(String state) {
    if (!enabled) return;
    switch (state) {
      case 'paused' || 'hidden':
        _backgroundFlush?.cancel();
        _backgroundFlush = Timer(const Duration(milliseconds: 500), () {
          _backgroundFlush = null;
          unawaited(sink.flush());
        });
      case 'resumed' || 'detached':
        _backgroundFlush?.cancel();
        _backgroundFlush = null;
    }
  }

  void flush() => unawaited(sink.flush());

  /// A frame's bytes in a scenario are its handle's UTF-8.
  static Uint8List bytesOfHandle(String handle) => utf8.encode(handle);

  static String handleOfBytes(Uint8List bytes) => utf8.decode(bytes);
}

/// The engine's `collector` configuration group as Dart sets it up.
typedef ScenarioCollector = ({
  bool enabled,
  TugboatCollectorConfig config,
  Duration identityDebounce,
});

/// Maps `configure.collector` onto [host]. Throws [UnsupportedError] for a
/// setting Dart fixes to another value.
ScenarioCollector scenarioCollector(
  TugboatCollectorConfig host,
  Map<String, Object?> collector,
) {
  for (final entry in _fixedInDart.entries) {
    final value = collector[entry.key];
    if (value != null && value != entry.value) {
      throw UnsupportedError(
        'Dart fixes collector.${entry.key} to ${entry.value}',
      );
    }
  }
  int setting(String key, int fallback) => (collector[key] ?? fallback) as int;
  return (
    enabled: (collector['enabled'] ?? false) as bool,
    config: TugboatCollectorConfig(
      baseUrl: host.baseUrl,
      apiKey: host.apiKey,
      appInfo: host.appInfo,
      deviceInfo: host.deviceInfo,
      ipInfo: host.ipInfo,
      locale: host.locale,
      userId: host.userId,
      eventBatchSize: setting('batchSize', 10),
      eventFlushInterval: Duration(
        milliseconds: setting('flushIntervalMs', 3000),
      ),
      maxPendingBatches: setting('maxPendingBatches', 20),
      maxPendingEvents: setting('maxPendingEvents', 60),
      maxPendingFrames: setting('maxPendingFrames', 20),
      retryAfterCap: Duration(milliseconds: setting('maxRetryAfterMs', 60000)),
      endingRetryAfterCap: Duration(
        milliseconds: setting('maxEndingRetryAfterMs', 10000),
      ),
    ),
    identityDebounce: Duration(
      milliseconds: setting('identityDebounceMs', 3000),
    ),
  );
}

/// Engine settings Dart cannot vary: the frame chunk and timeout are
/// constants in `CollectorHttpSink`, the background delay is the widget's,
/// and the JSON timeout (C3), the end drain (C5), event-lane gaps (C6), and
/// the answer deadline (C15) do not exist in Dart.
const _fixedInDart = <String, Object>{
  'frameChunk': 20,
  'frameTimeoutMs': 15000,
  'jsonTimeoutMs': 15000,
  'backgroundFlushDelayMs': 500,
  'endDrainTimeoutMs': 5000,
  'answerGraceMs': 5000,
  'reportEventLaneGaps': false,
};

/// The effects of an engine step that Dart can produce: `http.send` only,
/// without `timeoutMs` on JSON posts (see the header).
List<Map<String, Object?>> comparableEffects(List<Object?> effects) => [
  for (final effect in effects.cast<Map<String, Object?>>())
    if (effect['type'] == 'http.send')
      {
        for (final entry in effect.entries)
          if (entry.key != 'timeoutMs' || effect['lane'] == 'frames')
            entry.key: entry.value,
      },
];

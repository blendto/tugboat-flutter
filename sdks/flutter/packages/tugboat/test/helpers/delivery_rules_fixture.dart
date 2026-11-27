// Runs `delivery.rules` fixtures (conformance/README.md) against the real
// `CollectorHttpSink`: the collector delivery rules that Dart and the C++
// engine share, written as actions (record an event, capture a frame, answer
// the request in flight) and what delivery sends and reports after each. The
// C++ counterpart is core/session-engine/tests/conformance/
// delivery_rules_runner.cpp; both read the same fixtures and summarise
// requests and health the same way.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tugboat/src/capture_sink.dart';
import 'package:tugboat/src/collector_config.dart';
import 'package:tugboat/src/collector_http_sink.dart';
import 'package:tugboat/src/models.dart';

import 'conformance_fixture.dart';

const _startWallUs = 1781827200000000;
const _collectorKeys = {
  'batchSize',
  'maxPendingEvents',
  'maxPendingBatches',
  'maxPendingFrames',
  'maxPendingFrameBytes',
};

/// Runs [fixture] on a fresh sink. Returns one line per difference; empty
/// when Dart behaves as the fixture says.
Future<List<String>> runDeliveryRulesOnDart(
  ConformanceFixture fixture,
  Directory root,
) async {
  final run = _Run(fixture, readConformancePresets(root)['default-host']!);
  try {
    return await run.run();
  } finally {
    await run.dispose();
  }
}

class _Run {
  _Run(this.fixture, Map<String, Object?> host)
    : client = _RulesClient(),
      _host = decodeConformanceHost(host);

  final ConformanceFixture fixture;
  final _RulesClient client;
  final TugboatCollectorConfig _host;
  late final CollectorHttpSink _sink;

  /// The sink hub the controller puts in front of the sink: its counters are
  /// Dart's own `accepted`, `pending`, and `dropped`.
  late final TugboatCaptureSinkHub _hub;
  late TugboatSession _session;
  int _nextEvent = 0;
  int _sessions = 0;

  int _nextFrame = 1;

  Future<void> dispose() async {
    // Pending requests would otherwise keep the sink's timers alive.
    client.failAll();
    _sink.dispose();
  }

  List<Map<String, Object?>> get _steps =>
      (fixture.input['steps']! as List).cast<Map<String, Object?>>();

  Future<List<String>> run() async {
    final collector = (fixture.input['collector']! as Map)
        .cast<String, Object?>();
    for (final key in collector.keys) {
      if (!_collectorKeys.contains(key)) {
        return ['unknown collector setting $key'];
      }
    }
    int setting(String key, int fallback) =>
        (collector[key] ?? fallback) as int;
    _sink = CollectorHttpSink(
      config: TugboatCollectorConfig(
        baseUrl: _host.baseUrl,
        apiKey: _host.apiKey,
        appInfo: _host.appInfo,
        deviceInfo: _host.deviceInfo,
        ipInfo: _host.ipInfo,
        locale: _host.locale,
        userId: _host.userId,
        eventBatchSize: setting('batchSize', 10),
        // No periodic flush: the fixture's actions are the only triggers.
        eventFlushInterval: const Duration(days: 1),
        maxPendingBatches: setting('maxPendingBatches', 20),
        maxPendingEvents: setting('maxPendingEvents', 60),
        maxPendingFrames: setting('maxPendingFrames', 400),
        maxPendingFrameBytes: setting('maxPendingFrameBytes', 8 * 1024 * 1024),
      ),
      client: client,
    );
    _session = TugboatSession(
      id: 'session-$_startWallUs',
      startedAt: DateTime.fromMicrosecondsSinceEpoch(_startWallUs, isUtc: true),
      platform: 'android',
      viewport: const TugboatRect(0, 0, 412, 915),
    );
    // Setup: start the session and complete the collector handshake.
    _hub = TugboatCaptureSinkHub([_sink]);
    _startSession();
    await _settle();
    client.answer(status: 202, body: jsonEncode({'sessionId': 'srv-1'}));
    await _settle();
    client.takeSent();

    final expected = (fixture.expected['steps']! as List)
        .cast<Map<String, Object?>>();
    if (expected.length != _steps.length) {
      return ['expected.steps needs one entry per input step'];
    }
    for (var i = 0; i < _steps.length; i++) {
      final action = (_steps[i]['do']! as Map).cast<String, Object?>();
      await _act(action);
      await _settle();
      final actual = {
        'sent': client.takeSent(),
        'health': {
          'pending': _hub.pendingCount,
          'accepted': _hub.acceptCount,
          'dropped': _hub.dropCount,
        },
      };
      final mismatches = diffJson(expected[i], actual, '\$.expected.steps[$i]');
      if (mismatches.isNotEmpty) {
        return [...mismatches, 'actual: ${jsonEncode(actual)}'];
      }
    }
    return const [];
  }

  /// The controller starts the sinks, then records `session_start` through
  /// the hub (the collector sink leaves it to its lifecycle lane).
  void _startSession() {
    _hub.startSession(_session);
    _hub.recordEvent(
      TugboatEvent(id: 'event-${_nextEvent++}', atMs: 0, type: 'session_start'),
    );
  }

  /// Lets the sink run until it waits on the collector again.
  Future<void> _settle() => pumpEventQueue(times: 60);

  Future<void> _act(Map<String, Object?> action) async {
    if (action['newSession'] != null) {
      _sessions += 1;
      final wallUs = _startWallUs + _sessions * 1000000;
      _session = TugboatSession(
        id: 'session-$wallUs',
        startedAt: DateTime.fromMicrosecondsSinceEpoch(wallUs, isUtc: true),
        platform: 'android',
        viewport: const TugboatRect(0, 0, 412, 915),
      );
      // The old session ends (`session_end`) and the new one starts.
      _hub.recordEvent(
        TugboatEvent(
          id: 'event-${_nextEvent++}',
          atMs: _nextEvent * 10,
          type: 'session_end',
        ),
      );
      _startSession();
    } else if (action['lifecycleFrame'] case final Map<String, Object?> frame) {
      // The app goes to the background and returns; the lifecycle capture's
      // frame is referenced by no event.
      for (final type in const ['app_backgrounded', 'app_foregrounded']) {
        _hub.recordEvent(
          TugboatEvent(
            id: 'event-${_nextEvent++}',
            atMs: _nextEvent * 10,
            type: type,
          ),
        );
      }
      _recordFrame(frame['bytes'] as int? ?? 48000);
    } else if (action['event'] case final String name) {
      _hub.recordEvent(
        TugboatEvent(
          id: 'event-${_nextEvent++}',
          atMs: _nextEvent * 10,
          type: 'external_event',
          stream: TugboatEventStream.evidence,
          data: {'name': name},
        ),
      );
    } else if (action['frame'] case final Map<String, Object?> frame) {
      // A swipe: the frame, then the interaction event that references it.
      final id = _recordFrame(frame['bytes'] as int? ?? 48000);
      _hub.recordEvent(
        TugboatEvent(
          id: 'event-${_nextEvent++}',
          atMs: _nextEvent * 10,
          type: 'interaction',
          afterFrame: id,
          data: const {'interactionSchema': 2, 'gesture': 'swipe'},
        ),
      );
    } else if (action['initialFrame'] case final Map<String, Object?> frame) {
      _recordFrame(frame['bytes'] as int? ?? 48000);
    } else if (action['flush'] != null) {
      unawaited(_sink.flush());
    } else if (action['answer'] case final Map<String, Object?> answer) {
      client.answer(
        outcome: answer['outcome'] as String? ?? 'http',
        status: answer['status'] as int?,
      );
    } else {
      throw ArgumentError('unknown action $action');
    }
  }

  String _recordFrame(int bytes) {
    final id = 'frame-${_nextFrame++}';
    _hub.recordFrame(
      TugboatFrame(
        id: id,
        atMs: _nextEvent * 10,
        width: 1080,
        height: 2400,
        contentHash: 'hash-$id',
        masked: true,
        trigger: TugboatFrameTrigger.lifecycle,
        byteLength: bytes,
        captureMicros: 12000,
        captureSessionId: _session.id,
      ),
      Uint8List(bytes),
      sessionId: _session.id,
    );
    return id;
  }
}

/// The collector endpoint: summarises each request the sink sends and holds
/// it until an action answers it. Delivery is single-flight, so at most one
/// request is in flight.
class _RulesClient extends http.BaseClient {
  final List<Map<String, Object?>> _sent = [];
  Completer<http.StreamedResponse>? _inFlight;

  List<Map<String, Object?>> takeSent() {
    final taken = List.of(_sent);
    _sent.clear();
    return taken;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_inFlight != null) {
      throw StateError('a second request while one is in flight');
    }
    final summary = await _summarize(request);
    final response = Completer<http.StreamedResponse>();
    _inFlight = response;
    _sent.add(summary);
    return response.future;
  }

  Future<Map<String, Object?>> _summarize(http.BaseRequest request) async {
    final path = request.url.path;
    if (request is http.MultipartRequest) {
      final numbers = request.fields['frameNos']!.split(',');
      return {
        'lane': 'frames',
        'frames': [for (final number in numbers) int.parse(number)],
      };
    }
    final body =
        jsonDecode(await request.finalize().bytesToString())
            as Map<String, Object?>;
    if (path == '/v1/sessions') {
      return {'lane': 'lifecycle', 'eventType': body['eventType']};
    }
    return {
      'lane': 'events',
      'events': [
        for (final event in (body['events']! as List).cast<Map>())
          _eventName(event.cast<String, Object?>()),
      ],
    };
  }

  /// An external event is its name, a diagnostic its component and result,
  /// anything else its type.
  String _eventName(Map<String, Object?> event) {
    final type = event['eventType'] as String?;
    final payload = event['payload'] as Map<String, Object?>?;
    if (type == 'external_event' && payload?['name'] is String) {
      return payload!['name']! as String;
    }
    if (type == 'capture_diagnostic' && payload != null) {
      return 'diag:${payload['component']}:${payload['result']}';
    }
    return '$type';
  }

  /// Answers the request in flight.
  void answer({String outcome = 'http', int? status, String body = ''}) {
    final response = _inFlight;
    if (response == null) {
      throw StateError('answer: no request is in flight');
    }
    _inFlight = null;
    switch (outcome) {
      case 'http':
        response.complete(
          http.StreamedResponse(Stream.value(utf8.encode(body)), status!),
        );
      case 'timeout':
        response.completeError(TimeoutException('rules timeout'));
      default:
        response.completeError(http.ClientException('rules error'));
    }
  }

  void failAll() {
    final response = _inFlight;
    _inFlight = null;
    if (response != null && !response.isCompleted) {
      response.completeError(http.ClientException('rules finished'));
    }
  }
}

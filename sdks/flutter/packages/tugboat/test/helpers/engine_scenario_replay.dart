// Delivery replay: runs an `engine.scenario` marked `dartParity: "delivery"`
// against the real `CollectorHttpSink`, comparing only the `http.send`
// effects. It holds the collector wire (batching, frame chunks, 400
// isolation and retry offsets, requeue order, eviction, the failed latch,
// and their request bodies) to Dart even where the scenario cannot run on
// the Dart controller: frames that come from interactions, or records the
// engine publishes and Dart does not (change C6).
//
// How a step maps onto the sink:
// - The sink is fed the records the engine published (`expect.records`),
//   in order, the way the controller's sink hub feeds it: event records
//   through `recordEvent`, frame records through `recordFrame` (the bytes
//   are the handle's UTF-8). The engine's own delivery gap records
//   (`collector-…` ids) are not fed: Dart's sink makes its own diagnostics,
//   and their wire bodies are compared.
// - `session.start` starts the sink with the session the engine would
//   build; `session.end` (and `detached`) ends it once, after its records.
// - Identity, transport, flush, and background flush steps call the sink as
//   in engine_scenario.dart; time runs on the same deterministic scheduler.
// - Every other message (interaction facts, `capture.result`,
//   `event.record`, `timer.fired`) needs no call: its records are fed.
import 'dart:async';

import 'package:tugboat/src/models.dart';
import 'package:tugboat/src/screenshot_capture_backend.dart';

import 'conformance_fixture.dart';
import 'engine_scenario_delivery.dart';

/// Replays [fixture] into the real collector sink. Returns one line per
/// `http.send` difference; empty when Dart sends the same requests.
List<String> replayDeliveryOnDart(ConformanceFixture fixture) {
  final scheduler = ScenarioScheduler();
  return scheduler.run(() => _Replay(fixture, scheduler).run());
}

class _Replay {
  _Replay(this.fixture, this._scheduler)
    : _steps = (fixture.input['steps']! as List).cast<Map<String, Object?>>();

  final ConformanceFixture fixture;
  final ScenarioScheduler _scheduler;
  final List<Map<String, Object?>> _steps;
  late final ScenarioDelivery _delivery;
  int _wallOffsetUs = 0;
  String? _sessionId;
  bool _ended = true;

  List<String> run() {
    try {
      _delivery = _buildDelivery();
      return _run();
    } on UnsupportedError catch (error) {
      return ['${error.message}; drop dartParity on this fixture'];
    }
  }

  ScenarioDelivery _buildDelivery() {
    final configure = fixture.input['configure']! as Map<String, Object?>;
    final host = decodeConformanceHost(
      configure['host']! as Map<String, Object?>,
    );
    return ScenarioDelivery(
      collector: scenarioCollector(
        host,
        (configure['collector'] ?? const <String, Object?>{})
            as Map<String, Object?>,
      ),
      scheduler: _scheduler,
      now: () => DateTime.fromMicrosecondsSinceEpoch(
        _scheduler.nowUs + _wallOffsetUs,
        isUtc: true,
      ),
    );
  }

  List<String> _run() {
    for (var i = 0; i < _steps.length; i++) {
      final expect = _steps[i]['expect']! as Map<String, Object?>;
      if (expect.containsKey('error')) continue;
      final before = _delivery.client.effects.length;
      _step(
        _steps[i]['send']! as Map<String, Object?>,
        (expect['records']! as List).cast<Map<String, Object?>>(),
      );
      _scheduler.flushMicrotasks();
      final mismatches = diffJson(
        comparableEffects(expect['effects']! as List),
        _delivery.client.effects.sublist(before),
        '\$.input.steps[$i].expect.effects',
      );
      if (mismatches.isNotEmpty) return mismatches;
    }
    return const [];
  }

  void _step(Map<String, Object?> send, List<Map<String, Object?>> records) {
    final at = send['at'] as Map<String, Object?>?;
    if (at != null) _advance(at);
    final input =
        (send['input'] ?? const <String, Object?>{}) as Map<String, Object?>;
    switch (send['type']) {
      case 'session.start':
        _start(input, at!);
        _feed(records);
      case 'session.end':
        _feed(records);
        _end();
      case 'app.lifecycle':
        _delivery.appLifecycle(input['state']! as String);
        _feed(records);
        if (input['state'] == 'detached') _end();
      case 'identity.set':
        unawaited(_delivery.sink.setUserId(input['userId'] as String?));
      case 'traits.set':
        unawaited(
          _delivery.sink.setTraits(
            Map<String, dynamic>.from(input['traits']! as Map),
          ),
        );
      case 'transport.result':
        _delivery.client.answer(input);
        _afterAction(records);
      case 'transport.flush':
        _delivery.flush();
        _afterAction(records);
      case 'batch' || 'engine.dispose':
        throw UnsupportedError(
          'delivery replay does not model ${send['type']}',
        );
      default:
        _feed(records);
    }
  }

  void _advance(Map<String, Object?> at) {
    final monoUs = at['monoUs']! as int;
    final wallUs = at['wallUs'] as int?;
    if (wallUs != null) _wallOffsetUs = wallUs - monoUs;
    _scheduler.advanceTo(monoUs);
  }

  /// Records a step's message caused are fed once its own action ran.
  void _afterAction(List<Map<String, Object?>> records) {
    _scheduler.flushMicrotasks();
    _feed(records);
  }

  void _start(Map<String, Object?> input, Map<String, Object?> at) {
    final wallUs = at['wallUs']! as int;
    final viewport = input['viewport']! as Map<String, Object?>;
    final session = TugboatSession(
      id: 'session-$wallUs',
      startedAt: DateTime.fromMicrosecondsSinceEpoch(wallUs, isUtc: true),
      platform: input['platform']! as String,
      viewport: TugboatRect(
        0,
        0,
        (viewport['width']! as num).toDouble(),
        (viewport['height']! as num).toDouble(),
      ),
      locale: decodeConformanceLocale(input['locale'], 'locale'),
    );
    _sessionId = session.id;
    _ended = false;
    _delivery.sink.startSession(session);
  }

  void _end() {
    if (_ended) return;
    _ended = true;
    unawaited(_delivery.sink.endSession());
  }

  void _feed(List<Map<String, Object?>> records) {
    for (final record in records) {
      switch (record['kind']) {
        case 'event':
          final event = record['event']! as Map<String, Object?>;
          if ((event['id']! as String).startsWith('collector-')) continue;
          _delivery.sink.recordEvent(decodeConformanceRecordedEvent(event));
        case 'frame':
          final handle = record['handle']! as String;
          _delivery.sink.recordFrame(
            _decodeFrame(record['frame']! as Map<String, Object?>),
            ScenarioDelivery.bytesOfHandle(handle),
            sessionId: _sessionId!,
          );
      }
    }
  }
}

TugboatFrame _decodeFrame(Map<String, Object?> json) => TugboatFrame(
  id: json['id']! as String,
  atMs: json['atMs']! as int,
  width: json['width']! as int,
  height: json['height']! as int,
  contentHash: json['contentHash']! as String,
  masked: json['masked']! as bool,
  trigger: TugboatFrameTrigger.values.byName(json['trigger']! as String),
  byteLength: json['byteLength']! as int,
  captureMicros: json['captureMicros']! as int,
  captureSessionId: json['captureSessionId'] as String?,
  requestedBackend: TugboatScreenshotCaptureBackend.tryParse(
    json['requestedBackend'] as String?,
  ),
  resolvedBackend: TugboatScreenshotCaptureBackend.tryParse(
    json['resolvedBackend'] as String?,
  ),
  fallbackReason: json['fallbackReason'] as String?,
);

// Runs `engine.scenario` fixtures (conformance/engine/scenario/) against the
// real Dart controller, so the C++ session engine and the shipped Dart
// session model are held to the same records.
//
// How a scenario maps onto Dart:
// - `engine.configure` becomes the controller's [TugboatReplayConfig]
//   (`host.app` -> appInfo, `limits`), fixed for the controller's life.
// - Each step's `at` drives the controller's clocks: `wallUs` through
//   `debugNow` (session id, startedAt), `monoUs` through the injected
//   elapsed clock (`atMs`).
// - Messages call the controller's own entry points: `start`, `endSession`,
//   `recordAppLifecycleState` (plus `endSession` on `detached`, as the
//   widget does), `recordLocale`, and `debugRecordEvent` (the evidence
//   recorder's admission and append path). `identity.set` drives a real
//   [CollectorHttpSink], whose runtime user id is what Dart stamps at record
//   time. `timer.fired` has no Dart counterpart; Dart owns no engine timers.
// - Records are the events the controller publishes to its capture sinks,
//   in order, each with the collector sink's user id at that moment.
//
// What is not compared:
// - Fixtures whose `runners` exclude `dart` (including every `engineOnly`
//   scenario) are skipped by the caller.
// - Steps that expect an `error` pin the engine's message validation. Dart's
//   typed API cannot express a malformed message, so those steps are not
//   sent.
// - `attachActionContext`: Dart's evidence path never attaches action
//   context; with no exploration action window (deferred beyond this
//   milestone) both values enrich identically.
// - `capture.request` effects. Dart's capture scheduler is async work this
//   runner holds, so it never reaches the host. The ids it mints are still
//   compared, exactly: `capture_request-N` when a session starts and on
//   `resumed`, and `capture_execution-N` for each request a teardown
//   cancels share the event-id counter, so every later event id depends on
//   them. Any other effect is reported as unmodelled.
// - Async work is held, never run: everything these scenarios cover happens
//   synchronously in Dart, and held capture work cannot add records.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tugboat/src/capture_sink.dart';
import 'package:tugboat/src/collector_http_sink.dart';
import 'package:tugboat/src/controller.dart';
import 'package:tugboat/src/controller_clock.dart';
import 'package:tugboat/src/models.dart';

import 'conformance_fixture.dart';

/// Runs [fixture] on a fresh Dart controller. Returns one line per
/// difference from the fixture's expectations; empty when Dart matches.
List<String> runEngineScenarioOnDart(ConformanceFixture fixture) {
  return _holdingAsyncWork(() => _ScenarioRun(fixture).run());
}

T _holdingAsyncWork<T>(T Function() body) => runZoned(
  body,
  zoneSpecification: ZoneSpecification(
    scheduleMicrotask: (self, parent, zone, task) {},
    createTimer: (self, parent, zone, duration, callback) => _HeldTimer(),
    createPeriodicTimer: (self, parent, zone, period, callback) => _HeldTimer(),
  ),
);

class _HeldTimer implements Timer {
  @override
  bool get isActive => false;

  @override
  int get tick => 0;

  @override
  void cancel() {}
}

/// Both scenario clocks: `at.monoUs` and `at.wallUs` of the current step.
class _ScenarioClock implements TugboatElapsedClock {
  int monoUs = 0;
  int wallUs = 0;
  int _startMonoUs = 0;

  DateTime now() => DateTime.fromMicrosecondsSinceEpoch(wallUs, isUtc: true);

  @override
  int get elapsedMilliseconds => (monoUs - _startMonoUs) ~/ 1000;

  @override
  void restart() {
    _startMonoUs = monoUs;
  }
}

/// Collects every event the controller publishes, with the record-time
/// user id.
class _RecordingSinks implements TugboatCaptureSinkFactory {
  _RecordingSinks(this._userId);

  final String? Function() _userId;
  final List<Map<String, Object?>> records = [];

  @override
  TugboatSessionCaptureSink create(TugboatSinkSessionContext context) =>
      _RecordingSink(this);
}

class _RecordingSink implements TugboatSessionCaptureSink {
  _RecordingSink(this._owner);

  final _RecordingSinks _owner;

  @override
  Future<void> start(TugboatSinkSessionContext context) async {}

  @override
  void accept(TugboatCaptureEnvelope envelope) {
    final event = envelope.event;
    if (envelope.kind != TugboatEnvelopeKind.event || event == null) return;
    _owner.records.add({
      'kind': 'event',
      'event': _plainJson(event.toJson()),
      'userId': _owner._userId(),
    });
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> finish() async {}

  @override
  Future<void> dispose() async {}
}

Object? _plainJson(Object? value) => jsonDecode(jsonEncode(value));

/// A scenario the Dart runner cannot express. Reported as a mismatch, so
/// the fixture must set `runners: ["cpp"]` instead.
class _Unmodelled implements Exception {
  _Unmodelled(this.message);

  final String message;
}

/// The per-controller values Dart takes at construction, which the engine
/// takes per `session.start`.
typedef _ControllerIdentity = ({
  String? activationRequestId,
  String? explorationRunId,
  int sessionEpoch,
});

class _ScenarioRun {
  _ScenarioRun(this.fixture)
    : _steps = (fixture.input['steps']! as List).cast<Map<String, Object?>>();

  final ConformanceFixture fixture;
  final List<Map<String, Object?>> _steps;
  final _ScenarioClock _clock = _ScenarioClock();
  late final _RecordingSinks _sinks = _RecordingSinks(() => _identity?.userId);
  CollectorHttpSink? _identity;
  late final TugboatReplayController _controller;
  late final _ControllerIdentity _controllerIdentity;

  List<String> run() {
    try {
      return _run();
    } on _Unmodelled catch (unmodelled) {
      return ['${unmodelled.message}; set "runners": ["cpp"] on this fixture'];
    }
  }

  List<String> _run() {
    _controllerIdentity = _firstStartIdentity();
    _controller = _buildController();
    for (var i = 0; i < _steps.length; i++) {
      final expect = _steps[i]['expect']! as Map<String, Object?>;
      if (expect.containsKey('error')) continue;
      final before = _sinks.records.length;
      _send(_steps[i]['send']! as Map<String, Object?>);
      final path =
          r'$.input.steps['
          '$i'
          '].expect';
      final mismatches = _compareStep(expect, before, path);
      if (mismatches.isNotEmpty) return mismatches;
    }
    return _compareSnapshot();
  }

  List<String> _compareStep(
    Map<String, Object?> expect,
    int before,
    String path,
  ) {
    final actual = _sinks.records.sublist(before);
    final out = diffJson(
      _plainJson(expect['records']),
      _plainJson(actual),
      '$path.records',
    );
    final unmodelled = [
      for (final effect in expect['effects']! as List)
        if ((effect as Map)['type'] != 'capture.request') effect['type'],
    ];
    if (unmodelled.isNotEmpty) {
      out.add('$path.effects: the Dart runner does not model $unmodelled');
    }
    return out;
  }

  List<String> _compareSnapshot() {
    final expected = fixture.expected['finalSnapshot'] as Map?;
    final session = _controller.session;
    final actual = session == null
        ? null
        : _plainJson(session.toJson())! as Map;
    return diffJson(
      expected == null ? null : _plainJson(expected),
      actual,
      r'$.expected.finalSnapshot',
    );
  }

  _ControllerIdentity _firstStartIdentity() {
    for (final message in _sentMessages()) {
      if (message['type'] != 'session.start') continue;
      return _startIdentity(message['input']! as Map<String, Object?>);
    }
    return (activationRequestId: null, explorationRunId: null, sessionEpoch: 0);
  }

  Iterable<Map<String, Object?>> _sentMessages() sync* {
    for (final step in _steps) {
      final expect = step['expect']! as Map<String, Object?>;
      if (expect.containsKey('error')) continue;
      final send = step['send']! as Map<String, Object?>;
      if (send['type'] == 'batch') {
        yield* (send['messages']! as List).cast<Map<String, Object?>>();
      } else {
        yield send;
      }
    }
  }

  _ControllerIdentity _startIdentity(Map<String, Object?> input) => (
    activationRequestId: input['activationRequestId'] as String?,
    explorationRunId: input['explorationRunId'] as String?,
    sessionEpoch: input['sessionEpoch']! as int,
  );

  TugboatReplayController _buildController() {
    final configure = fixture.input['configure']! as Map<String, Object?>;
    final unsupported = configure.keys.toSet().difference({'host', 'limits'});
    if (unsupported.isNotEmpty) {
      throw _Unmodelled('Dart runner does not model configure $unsupported');
    }
    final hostJson = configure['host'] as Map<String, Object?>?;
    final host = hostJson == null ? null : decodeConformanceHost(hostJson);
    if (host != null) {
      _identity = CollectorHttpSink(
        config: host,
        client: MockClient((_) async => http.Response('', 503)),
      );
    }
    final limits =
        (configure['limits'] ?? const <String, Object?>{})
            as Map<String, Object?>;
    return TugboatReplayController(
      config: TugboatReplayConfig(
        appInfo: host?.appInfo,
        maxEvents: (limits['maxEvents'] ?? 5000) as int,
        maxFrames: (limits['maxFrames'] ?? 500) as int,
        explorationRunId: _controllerIdentity.explorationRunId,
        sinkFactories: [_sinks],
      ),
      boundaryKey: GlobalKey(),
      activationRequestId: _controllerIdentity.activationRequestId,
      sessionEpoch: _controllerIdentity.sessionEpoch,
      debugClock: _clock,
    )..debugNow = _clock.now;
  }

  void _send(Map<String, Object?> message) {
    final type = message['type']! as String;
    if (type == 'batch') {
      for (final inner in message['messages']! as List) {
        _send(inner as Map<String, Object?>);
      }
      return;
    }
    _setClock(message['at'] as Map<String, Object?>?);
    final handler = _handlers[type];
    if (handler == null) {
      throw _Unmodelled('Dart runner does not model $type');
    }
    handler(message['input']! as Map<String, Object?>);
  }

  /// One Dart entry point per engine message type.
  late final Map<String, void Function(Map<String, Object?> input)> _handlers =
      {
        'session.start': _start,
        'session.end': (_) => unawaited(_controller.endSession()),
        'app.lifecycle': (input) => _appLifecycle(input['state']! as String),
        'identity.set': (input) =>
            unawaited(_identity?.setUserId(input['userId'] as String?)),
        'locale.set': (input) => _controller.recordLocale(
          decodeConformanceLocale(input['locale'], 'locale')!,
        ),
        'event.record': _recordEvent,
        // Dart owns no engine timers; the engine ignores unknown timer ids.
        'timer.fired': (_) {},
        'engine.configure': _reconfigure,
      };

  /// Dart fixes the configuration per controller, so only a configure that
  /// repeats the scenario's own can be expressed.
  void _reconfigure(Map<String, Object?> input) {
    if (diffJson(fixture.input['configure'], input).isNotEmpty) {
      throw _Unmodelled('Dart fixes the configuration per controller');
    }
  }

  void _setClock(Map<String, Object?>? at) {
    if (at == null) return;
    _clock.monoUs = at['monoUs']! as int;
    final wallUs = at['wallUs'] as int?;
    if (wallUs != null) _clock.wallUs = wallUs;
  }

  void _start(Map<String, Object?> input) {
    if (_startIdentity(input) != _controllerIdentity) {
      throw _Unmodelled(
        'Dart fixes activationRequestId, explorationRunId, and sessionEpoch '
        'per controller, but the scenario varies them per session.start',
      );
    }
    final viewport = input['viewport']! as Map<String, Object?>;
    _controller.start(
      Size(
        (viewport['width']! as num).toDouble(),
        (viewport['height']! as num).toDouble(),
      ),
      input['platform']! as String,
      locale: decodeConformanceLocale(input['locale'], 'locale'),
    );
  }

  void _appLifecycle(String name) {
    final state = AppLifecycleState.values.byName(name);
    _controller.recordAppLifecycleState(state);
    // TugboatReplay's widget ends the session on detached.
    if (state == AppLifecycleState.detached) {
      unawaited(_controller.endSession());
    }
  }

  void _recordEvent(Map<String, Object?> input) {
    final atMonoUs = input['atMonoUs'] as int?;
    final monoUs = _clock.monoUs;
    if (atMonoUs != null) _clock.monoUs = atMonoUs;
    final anchor = input['targetAnchor'] as Map<String, Object?>?;
    _controller.debugRecordEvent(
      type: input['eventType']! as String,
      stream: TugboatEventStream.parse(input['stream'] as String?),
      data:
          (input['data'] ?? const <String, Object?>{}) as Map<String, Object?>,
      targetAnchor: anchor == null ? null : decodeConformanceAnchor(anchor),
    );
    _clock.monoUs = monoUs;
  }
}

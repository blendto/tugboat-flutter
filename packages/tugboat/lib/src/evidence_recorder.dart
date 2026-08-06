import 'capture_profile.dart';
import 'external_event.dart';
import 'health.dart';
import 'models.dart';
import 'network_observer.dart';

enum _EvidenceKind { external, network }

/// Records `external_event` / `network_call` evidence for one capture session.
///
/// Owns admission, health counters, and network tokens. The host controller
/// supplies identity stamping + sink append via [appendEvidence].
class TugboatEvidenceRecorder {
  TugboatEvidenceRecorder({
    required this.appendEvidence,
    required this.nextEventId,
    required this.nowMs,
    required this.profile,
  });

  final void Function(TugboatEvent event) appendEvidence;
  final String Function(String prefix) nextEventId;
  final int Function() nowMs;
  final TugboatCaptureProfile Function() profile;

  static const int _maxCount = 10000;

  TugboatSession? _session;
  bool _closed = false;
  int _externalAccepted = 0;
  int _externalDropped = 0;
  int _networkAccepted = 0;
  int _networkDropped = 0;
  int _networkDuplicateFinishes = 0;
  String? _lastDropReason;

  bool get accepting => !_closed && _session != null;

  TugboatEvidenceHealth healthSnapshot() => TugboatEvidenceHealth(
    externalAccepted: _externalAccepted,
    externalDropped: _externalDropped,
    networkAccepted: _networkAccepted,
    networkDropped: _networkDropped,
    networkDuplicateFinishes: _networkDuplicateFinishes,
    lastDropReason: _lastDropReason,
  );

  /// Binds a new session and clears counters. Re-opens admission.
  void bindSession(TugboatSession session) {
    _session = session;
    _closed = false;
    _externalAccepted = 0;
    _externalDropped = 0;
    _networkAccepted = 0;
    _networkDropped = 0;
    _networkDuplicateFinishes = 0;
    _lastDropReason = null;
  }

  /// Fences further evidence (session ending / dispose).
  void close() {
    _closed = true;
  }

  void recordExternalEvent({
    required String name,
    String? source,
    Map<String, Object?>? parameters,
    TugboatParameterPolicy parameterPolicy = TugboatParameterPolicy.namesOnly,
  }) {
    try {
      if (!accepting) {
        _noteDrop(_EvidenceKind.external, 'no_active_session');
        return;
      }
      final admittedSessionId = _session?.id;
      if (admittedSessionId == null) {
        _noteDrop(_EvidenceKind.external, 'no_active_session');
        return;
      }
      final boundedName = boundExternalLabel(
        name,
        TugboatParameterLimits.maxNameLength,
      );
      if (boundedName == null) {
        _noteDrop(_EvidenceKind.external, 'invalid_name');
        return;
      }
      final boundedSource = boundExternalLabel(
        source,
        TugboatParameterLimits.maxSourceLength,
      );
      final effectivePolicy = parameterPolicy.effectiveFor(profile());
      final snapshot = snapshotExternalParameters(
        policy: effectivePolicy,
        parameters: parameters,
      );
      if (!accepting) {
        _noteDrop(_EvidenceKind.external, 'no_active_session');
        return;
      }
      if (_session?.id != admittedSessionId) {
        _noteDrop(_EvidenceKind.external, 'stale_session');
        return;
      }
      appendEvidence(
        TugboatEvent(
          id: nextEventId('event'),
          atMs: nowMs(),
          type: 'external_event',
          stream: TugboatEventStream.evidence,
          data: {
            if (boundedSource != null) 'source': boundedSource,
            'name': boundedName,
            'parameterKeys': snapshot.parameterKeys,
            if (snapshot.parameters != null) 'parameters': snapshot.parameters,
            'capture': snapshot.toCaptureMetadata(),
          },
        ),
      );
      _externalAccepted = _clamp(_externalAccepted + 1);
    } catch (_) {
      _noteDrop(_EvidenceKind.external, 'record_failed');
    }
  }

  /// Begins observation of one logical network call.
  ///
  /// [route] must already be a safe host-supplied template. Null/invalid routes
  /// return a no-op token without recording.
  TugboatNetworkCall beginNetworkCall({required String method, String? route}) {
    try {
      if (!accepting) {
        _noteDrop(_EvidenceKind.network, 'no_active_session');
        return const TugboatNoOpNetworkCall();
      }
      final normalizedMethod = normalizeNetworkMethod(method);
      final normalizedRoute = normalizeNetworkRoute(route);
      if (normalizedMethod == null || normalizedRoute == null) {
        _noteDrop(_EvidenceKind.network, 'invalid_route');
        return const TugboatNoOpNetworkCall();
      }
      final session = _session;
      if (session == null) {
        _noteDrop(_EvidenceKind.network, 'no_active_session');
        return const TugboatNoOpNetworkCall();
      }
      return _ActiveNetworkCall(
        recorder: this,
        sessionId: session.id,
        method: normalizedMethod,
        route: normalizedRoute,
        startedAtMs: nowMs(),
      );
    } catch (_) {
      _noteDrop(_EvidenceKind.network, 'begin_failed');
      return const TugboatNoOpNetworkCall();
    }
  }

  void _finishNetworkCall({
    required String sessionId,
    required String method,
    required String route,
    required int startedAtMs,
    required TugboatNetworkOutcome outcome,
    int? statusCode,
    int? attemptCount,
    Object? errorResponseBody,
  }) {
    try {
      if (!accepting) {
        _noteDrop(_EvidenceKind.network, 'no_active_session');
        return;
      }
      if (_session?.id != sessionId) {
        _noteDrop(_EvidenceKind.network, 'stale_session');
        return;
      }
      final durationMs = (nowMs() - startedAtMs).clamp(0, 24 * 60 * 60 * 1000);
      final errorBody = statusCode != null && statusCode >= 400
          ? snapshotNetworkErrorResponseBody(errorResponseBody)
          : null;
      appendEvidence(
        TugboatEvent(
          id: nextEventId('event'),
          atMs: nowMs(),
          type: 'network_call',
          stream: TugboatEventStream.evidence,
          data: {
            'method': method,
            'route': route,
            if (statusCode != null) 'statusCode': statusCode,
            'outcome': outcome.wireName,
            'durationMs': durationMs,
            if (attemptCount != null && attemptCount > 0)
              'attemptCount': attemptCount,
            if (errorBody != null) 'errorResponseBody': errorBody.value,
            if (errorBody != null)
              'errorResponseBodyCapture': errorBody.toCaptureMetadata(),
          },
        ),
      );
      _networkAccepted = _clamp(_networkAccepted + 1);
    } catch (_) {
      _noteDrop(_EvidenceKind.network, 'finish_failed');
    }
  }

  void _noteDuplicateFinish(String sessionId) {
    if (!accepting || _session?.id != sessionId) return;
    _networkDuplicateFinishes = _clamp(_networkDuplicateFinishes + 1);
  }

  void _noteDrop(_EvidenceKind kind, String reason) {
    switch (kind) {
      case _EvidenceKind.external:
        _externalDropped = _clamp(_externalDropped + 1);
      case _EvidenceKind.network:
        _networkDropped = _clamp(_networkDropped + 1);
    }
    _lastDropReason = reason;
  }

  int _clamp(int value) => value > _maxCount ? _maxCount : value;
}

class _ActiveNetworkCall implements TugboatNetworkCall {
  _ActiveNetworkCall({
    required TugboatEvidenceRecorder recorder,
    required this.sessionId,
    required this.method,
    required this.route,
    required this.startedAtMs,
  }) : _recorder = recorder;

  final TugboatEvidenceRecorder _recorder;
  final String sessionId;
  final String method;
  final String route;
  final int startedAtMs;
  bool _finished = false;

  @override
  void complete({
    int? statusCode,
    int? attemptCount,
    Object? errorResponseBody,
  }) {
    _finish(
      outcome: TugboatNetworkOutcome.response,
      statusCode: statusCode,
      attemptCount: attemptCount,
      errorResponseBody: errorResponseBody,
    );
  }

  @override
  void fail({
    required TugboatNetworkFailure failure,
    int? statusCode,
    int? attemptCount,
    Object? errorResponseBody,
  }) {
    _finish(
      outcome: failure.outcome,
      statusCode: statusCode,
      attemptCount: attemptCount,
      errorResponseBody: errorResponseBody,
    );
  }

  void _finish({
    required TugboatNetworkOutcome outcome,
    int? statusCode,
    int? attemptCount,
    Object? errorResponseBody,
  }) {
    if (_finished) {
      _recorder._noteDuplicateFinish(sessionId);
      return;
    }
    _finished = true;
    _recorder._finishNetworkCall(
      sessionId: sessionId,
      method: method,
      route: route,
      startedAtMs: startedAtMs,
      outcome: outcome,
      statusCode: statusCode,
      attemptCount: attemptCount,
      errorResponseBody: errorResponseBody,
    );
  }
}

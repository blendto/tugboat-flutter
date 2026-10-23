import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'capture_sink.dart';
import 'collector_config.dart';
import 'collector_lane_delays.dart';
import 'collector_mapper.dart';
import 'models.dart';
import 'sdk_version.dart';

part 'collector_frame_uploads.dart';

const _httpProofEnabled =
    kDebugMode && bool.fromEnvironment('TUGBOAT_HTTP_PROOF');

const _collectorHttpProofPaths = {
  '/v1/sessions',
  '/v1/events/batch',
  '/v1/frames',
};

final _safeHttpProofId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

/// Redacted Device Farm HTTP proof line. Never includes origins, queries,
/// payloads, or API keys.
@visibleForTesting
String formatCollectorHttpProofLine({
  required String path,
  String? localSessionId,
  String? returnedSessionId,
  int? statusCode,
  required int durationMs,
  Object? error,
}) {
  final safePath = _collectorHttpProofPaths.contains(path) ? path : 'redacted';
  final line =
      'TUGBOAT_HTTP method=POST path=$safePath '
      'localSessionId=${_safeHttpProofIdValue(localSessionId)} '
      'returnedSessionId=${_safeHttpProofIdValue(returnedSessionId)} '
      'status=${statusCode ?? 'null'} '
      'durationMs=$durationMs';
  if (error == null) return line;
  return '$line exception=${error.runtimeType}';
}

String _safeHttpProofIdValue(String? value) => value == null
    ? 'null'
    : _safeHttpProofId.hasMatch(value)
    ? value
    : 'redacted';

/// Best-effort HTTP sink for the standalone `tugboat-collector` service.
class CollectorHttpSink implements TugboatCaptureSink {
  CollectorHttpSink({
    required TugboatCollectorConfig config,
    http.Client? client,
    Map<String, dynamic>? initialTraits,
    String? initialTraitsId,
    String? initialUserId,
    @visibleForTesting Duration? identityDebounceDuration,
    @visibleForTesting DateTime Function()? debugNow,
    @visibleForTesting Duration Function()? debugElapsed,
    @visibleForTesting CollectorLaneTimerSchedule? debugScheduleLaneTimer,
  }) : _config = config,
       _maxRetryAfterMs = clampCollectorRetryAfterCapMs(config.retryAfterCap),
       _maxEndingRetryAfterMs = clampCollectorRetryAfterCapMs(
         config.endingRetryAfterCap,
       ),
       _now = debugNow ?? DateTime.now,
       _userId = initialUserId ?? config.userId,
       _traits = initialTraits == null
           ? null
           : Map<String, dynamic>.from(initialTraits),
       _traitsId = initialTraitsId,
       _identityDebounceDuration =
           identityDebounceDuration ?? _defaultIdentityDebounceDuration,
       _client = _CollectorHttpClient(
         inner: client ?? http.Client(),
         apiKey: config.apiKey,
         platform: config.deviceInfo.platform,
         buildNumber: config.appInfo.buildNumber,
         versionName: config.appInfo.version,
         appId: config.appInfo.appId,
       ) {
    _laneDelays = CollectorLaneDelays(
      _onLaneReady,
      elapsed: debugElapsed,
      scheduleTimer: debugScheduleLaneTimer,
    );
  }

  final TugboatCollectorConfig _config;
  final _CollectorHttpClient _client;

  /// [TugboatCollectorConfig.retryAfterCap] and
  /// [TugboatCollectorConfig.endingRetryAfterCap], clamped once here.
  final int _maxRetryAfterMs;
  final int _maxEndingRetryAfterMs;

  /// Wall clock for lifecycle `triggeredAt` and diagnostic `atMs`.
  /// [DateTime.now] unless a test injects one.
  final DateTime Function() _now;

  bool _disposed = false;
  TugboatSession? _session;

  /// Collector-issued id; null until session_start is accepted.
  String? _collectorSessionId;
  int _sessionEpoch = 0;
  Timer? _flushTimer;
  Future<void>? _flushInFlight;
  bool _framesNeedRetry = false;
  bool _frameUploadFailureReported = false;
  int _frameUploadDiagnosticSequence = 0;
  int _droppedFrameCount = 0;
  final List<Map<String, Object?>> _pendingEvents = [];
  final List<_PendingFrameUpload> _pendingFrames = [];
  final List<List<Map<String, Object?>>> _retryBatches = [];
  final List<_PendingSessionLifecycle> _pendingLifecycle = [];
  late final CollectorLaneDelays _laneDelays;
  bool _sessionEnding = false;

  /// `endSession` queued `session_end` for the current session.
  bool _sessionEndQueued = false;

  /// Runtime user id (may change via [setUserId]).
  String? _userId;

  /// Full traits bag last provided by the host (process-local).
  Map<String, dynamic>? _traits;

  /// Collector-issued traits dictionary id.
  String? _traitsId;

  /// How long to wait after the last identity change before posting.
  ///
  /// Boot flows often resolve userId and traits in separate calls (auth restore,
  /// billing, feature flags). Debouncing merges those into one lifecycle POST
  /// (`session_identify` when both change) instead of back-to-back
  /// `user_changed` / `traits_updated`.
  static const _defaultIdentityDebounceDuration = Duration(seconds: 3);

  final Duration _identityDebounceDuration;

  Timer? _identityDebounceTimer;
  bool _userDirty = false;
  bool _traitsDirty = false;
  DateTime? _userTriggeredAt;
  DateTime? _traitsTriggeredAt;

  Uri get _baseUri => Uri.parse(_config.baseUrl.replaceAll(RegExp(r'/+$'), ''));

  bool get _hasCollectorSessionId =>
      _collectorSessionId != null && _collectorSessionId!.isNotEmpty;

  /// Last collector-issued traits id, if any.
  String? get traitsId => _traitsId;

  /// Last host-provided traits bag, if any.
  Map<String, dynamic>? get traits =>
      _traits == null ? null : Map<String, dynamic>.unmodifiable(_traits!);

  /// Current runtime user id stamped on sessions and events.
  String? get userId => _userId;

  @override
  void startSession(TugboatSession session) {
    if (_disposed) return;
    _sessionEpoch += 1;
    _session = session;
    // Clear any prior collector-issued id so a new session cannot route to the old one.
    // Traits / traitsId persist across sessions for the process lifetime.
    _collectorSessionId = null;
    _pendingEvents.clear();
    _pendingFrames.clear();
    _retryBatches.clear();
    _pendingLifecycle.clear();
    _framesNeedRetry = false;
    _frameUploadFailureReported = false;
    _frameUploadDiagnosticSequence = 0;
    _droppedFrameCount = 0;
    _cancelIdentityDebounce();
    _userDirty = false;
    _traitsDirty = false;
    _userTriggeredAt = null;
    _traitsTriggeredAt = null;
    _sessionEnding = false;
    _sessionEndQueued = false;
    _laneDelays.clear();
    _scheduleFlushTimer();
    _enqueueSessionLifecycle(
      TugboatCollectorSessionEventType.sessionStart.wireValue,
      session.startedAt,
    );
    unawaited(_kickFlush());
  }

  @override
  void recordEvent(TugboatEvent event) {
    if (_disposed || _session == null) return;
    if (event.type == 'session_start' || event.type == 'session_end') {
      // Lifecycle is sent through POST /v1/sessions.
      return;
    }

    final session = _session!;
    // sessionId / traitsId are stamped at send time once known.
    _pendingEvents.add(
      mapTugboatEventToCollectorEvent(
        event: event,
        sessionStartedAt: session.startedAt,
        collectorConfig: _config,
        userId: _userId,
      ),
    );
    _trimPendingEvents();

    if (_pendingEvents.length >= _config.eventBatchSize) {
      unawaited(flush());
    }
  }

  @override
  void recordFrame(
    TugboatFrame frame,
    Uint8List bytes, {
    required String sessionId,
    String? actionId,
  }) {
    if (_disposed) return;
    // Enforce in release builds too — assert-only would let stale frames
    // upload under the wrong collector session after a rapid restart.
    final activeSession = _session;
    if (activeSession != null && activeSession.id != sessionId) {
      debugPrint(
        '[tugboat] collector dropped frame for stale sessionId: $sessionId '
        '(active=${activeSession.id})',
      );
      return;
    }
    final frameNo = frameNumberFromId(frame.id);
    if (frameNo == null) {
      debugPrint(
        '[tugboat] collector dropped frame with malformed id: ${frame.id}',
      );
      return;
    }
    _pendingFrames.add(
      _PendingFrameUpload(
        frameNo: frameNo,
        bytes: bytes,
        metadata: frame.toJson(),
      ),
    );
    _trimPendingFrames();
    // While a frame upload is retrying, rely on the periodic flush timer.
    if (!_framesNeedRetry) {
      unawaited(flush());
    }
  }

  @override
  Future<void> flush() {
    if (_disposed) return Future<void>.value();
    final active = _flushInFlight;
    if (active != null) return active;

    late final Future<void> operation;
    operation = _flushOnce().whenComplete(() {
      if (identical(_flushInFlight, operation)) {
        _flushInFlight = null;
      }
      _stopFlushTimerOnceSessionEndSettled();
    });
    _flushInFlight = operation;
    return operation;
  }

  /// The post-pass stop rule (the engine's `on_pass_finished`): once the
  /// queued `session_end` has left the lifecycle lane (accepted, or dropped
  /// for good, as the native `SessionEndWatcher.isFinal` settles it), the
  /// periodic flush stops. A `session_end` with a retry outcome stays queued
  /// and is re-posted on the periodic flush. Unlike the engine, there is no
  /// events or frames drain after `session_end`.
  void _stopFlushTimerOnceSessionEndSettled() {
    if (!_sessionEndQueued) return;
    if (_pendingLifecycle.any((p) => _isSessionEnd(p.eventType))) return;
    _cancelFlushTimer();
  }

  /// Runs [then] once any in-flight flush is done, unless disposed.
  Future<void> _afterInFlight(Future<void> Function() then) async {
    final active = _flushInFlight;
    if (active != null) await active;
    if (_disposed) return;
    await then();
  }

  /// Wait for any in-flight flush, then run another so newly enqueued work is sent.
  Future<void> _kickFlush() => _afterInFlight(flush);

  /// A lane's `Retry-After` wait is over. Like the identity debounce, the
  /// lifecycle lane drains every queued post, so a `session_end` queued
  /// behind the waiting head goes out too.
  void _onLaneReady(CollectorDeliveryLane lane) {
    if (_disposed) return;
    if (lane == CollectorDeliveryLane.lifecycle) {
      unawaited(_afterInFlight(_drainLifecyclePosts));
    } else {
      unawaited(_kickFlush());
    }
  }

  /// While the session ends, lifecycle waits use the shorter ending cap.
  int _retryAfterCapMs(CollectorDeliveryLane lane) =>
      lane == CollectorDeliveryLane.lifecycle && _sessionEnding
      ? _maxEndingRetryAfterMs
      : _maxRetryAfterMs;

  /// Registers a full traits snapshot with the collector.
  ///
  /// No-ops when [traits] equals the cached bag via [mapEquals] (shallow:
  /// nested maps/lists compared with `==`). While `session_start` is still
  /// pending, updates memory only (folded into start at send time). Otherwise
  /// debounces `traits_updated` or `session_identify` when combined with a
  /// pending user change within [_identityDebounceDuration].
  Future<void> setTraits(Map<String, dynamic> traits) async {
    if (_disposed) return;
    if (mapEquals(_traits, traits)) return;
    _traits = Map<String, dynamic>.from(traits);
    if (_session == null) return;
    if (_isSessionStartPending()) return;
    _traitsDirty = true;
    _traitsTriggeredAt = _now();
    _scheduleIdentityDebounce();
  }

  /// Updates the runtime user id and notifies the collector.
  ///
  /// No-ops when [userId] equals the current runtime id. While `session_start`
  /// is still pending, updates memory only (folded into start at send time).
  /// Otherwise debounces `user_changed` or `session_identify` when combined
  /// with a pending traits change within [_identityDebounceDuration].
  Future<void> setUserId(String? userId) async {
    if (_disposed) return;
    if (userId == _userId) return;
    _userId = userId;
    if (_session == null) return;
    if (_isSessionStartPending()) return;
    _userDirty = true;
    _userTriggeredAt = _now();
    _scheduleIdentityDebounce();
  }

  bool _isSessionStartPending() => _pendingLifecycle.any(
    (p) =>
        p.eventType == TugboatCollectorSessionEventType.sessionStart.wireValue,
  );

  void _scheduleIdentityDebounce() {
    _identityDebounceTimer?.cancel();
    _identityDebounceTimer = Timer(_identityDebounceDuration, () {
      _identityDebounceTimer = null;
      if (_disposed) return;
      _enqueueCoalescedIdentityUpdate();
      unawaited(_drainLifecyclePosts());
    });
  }

  void _cancelIdentityDebounce() {
    _identityDebounceTimer?.cancel();
    _identityDebounceTimer = null;
  }

  /// Flushes any debounced identity update immediately (no-op when clean).
  Future<void> _flushIdentityDebounce() async {
    _cancelIdentityDebounce();
    if (!_userDirty && !_traitsDirty) return;
    _enqueueCoalescedIdentityUpdate();
    await _drainLifecyclePosts();
  }

  DateTime _coalescedIdentityTriggeredAt() {
    if (_userDirty && _traitsDirty) return _latestIdentityTrigger();
    if (_userDirty) return _userTriggeredAt ?? _now();
    return _traitsTriggeredAt ?? _now();
  }

  DateTime _latestIdentityTrigger() {
    final userAt = _userTriggeredAt;
    final traitsAt = _traitsTriggeredAt;
    if (userAt != null && traitsAt != null) {
      return userAt.isAfter(traitsAt) ? userAt : traitsAt;
    }
    return userAt ?? traitsAt ?? _now();
  }

  void _enqueueCoalescedIdentityUpdate() {
    if (_disposed || _session == null) return;
    if (!_userDirty && !_traitsDirty) return;

    final eventType = _userDirty && _traitsDirty
        ? TugboatCollectorSessionEventType.sessionIdentify.wireValue
        : _userDirty
        ? TugboatCollectorSessionEventType.userChanged.wireValue
        : TugboatCollectorSessionEventType.traitsUpdated.wireValue;
    final triggeredAt = _coalescedIdentityTriggeredAt();

    _userDirty = false;
    _traitsDirty = false;
    _enqueueSessionLifecycle(eventType, triggeredAt);
    _userTriggeredAt = null;
    _traitsTriggeredAt = null;
  }

  @override
  Future<void> endSession() async {
    if (_disposed || _session == null) return;
    // Captured before the first await: a session started meanwhile is not
    // the one ending.
    final epoch = _sessionEpoch;
    await _flushIdentityDebounce();
    if (!_isCurrentEpoch(epoch)) return;
    _sessionEnding = true;
    _laneDelays.clampLifecycleEnding(_maxEndingRetryAfterMs);
    await flush();
    if (!_isCurrentEpoch(epoch)) return;
    _enqueueSessionLifecycle(
      TugboatCollectorSessionEventType.sessionEnd.wireValue,
      _now(),
    );
    _sessionEndQueued = true;
    // The periodic flush keeps running until `session_end` settles
    // ([_stopFlushTimerOnceSessionEndSettled]).
    await _drainLifecyclePosts();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelFlushTimer();
    _cancelIdentityDebounce();
    _userDirty = false;
    _traitsDirty = false;
    _userTriggeredAt = null;
    _traitsTriggeredAt = null;
    _client.close();
    _pendingEvents.clear();
    _pendingFrames.clear();
    _retryBatches.clear();
    _pendingLifecycle.clear();
    _laneDelays.clear();
    _sessionEnding = false;
    _sessionEndQueued = false;
    _flushInFlight = null;
    _session = null;
    _collectorSessionId = null;
    _sessionEpoch += 1;
  }

  bool _isCurrentEpoch(int epoch) => !_disposed && epoch == _sessionEpoch;

  void _scheduleFlushTimer() {
    _cancelFlushTimer();
    _flushTimer = Timer.periodic(_config.eventFlushInterval, (_) {
      unawaited(flush());
    });
  }

  void _cancelFlushTimer() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  void _enqueueSessionLifecycle(String eventType, DateTime triggeredAt) {
    _pendingLifecycle.add(
      _PendingSessionLifecycle(
        eventType: eventType,
        triggeredAt: triggeredAt,
        activeLocale:
            eventType == TugboatCollectorSessionEventType.sessionStart.wireValue
            ? _session?.locale
            : null,
      ),
    );
  }

  Future<void> _drainLifecyclePosts() async {
    while (!_disposed && _pendingLifecycle.isNotEmpty) {
      final head = _pendingLifecycle.first;
      await flush();
      // Stop only when the head was not accepted (still retrying). Advancing
      // from session_start → session_end must continue draining.
      if (_pendingLifecycle.isNotEmpty &&
          identical(head, _pendingLifecycle.first)) {
        return;
      }
    }
  }

  /// Sends the lifecycle head once. The caller checks the lifecycle lane is
  /// not waiting.
  Future<void> _flushLifecyclePosts() async {
    if (_pendingLifecycle.isEmpty || _disposed) return;
    final pending = _pendingLifecycle.first;
    final epoch = _sessionEpoch;

    final result = await _sendSessionLifecycle(pending, epoch);
    if (!_isCurrentEpoch(epoch)) return;
    // A dropped `session_end` is settled; other dropped posts stay queued.
    final settled =
        result == _SendResult.accepted ||
        (result == _SendResult.drop && _isSessionEnd(pending.eventType));
    if (settled) _pendingLifecycle.removeAt(0);
  }

  Future<_SendResult> _sendSessionLifecycle(
    _PendingSessionLifecycle pending,
    int epoch,
  ) async {
    final session = _session;
    if (session == null) return _SendResult.accepted;

    final eventType = pending.eventType;
    final traits = _traits;
    final body = mapTugboatSessionLifecycleToCollectorSession(
      eventType: eventType,
      sessionId: _sessionIdForLifecycle(eventType, session.id),
      sessionStartedAt: session.startedAt,
      triggeredAt: pending.triggeredAt,
      config: _config,
      userId: _userId,
      traits: traits,
      traitsId: traits == null ? _traitsId : null,
      activeLocale: pending.activeLocale,
    );

    final sent = await _collectorPost(
      CollectorDeliveryLane.lifecycle,
      '/v1/sessions',
      (url) => _client.post(
        url,
        headers: _CollectorHttpClient._jsonHeaders,
        body: jsonEncode(body),
      ),
      epoch,
    );
    final response = sent.response;
    if (sent.result == _SendResult.accepted && response != null) {
      _applyLifecycleResponse(eventType, response.body, session.id);
    }
    return sent.result;
  }

  String _sessionIdForLifecycle(String eventType, String localSessionId) =>
      _isSessionStart(eventType)
      ? localSessionId
      : _collectorSessionId ?? localSessionId;

  bool _isSessionStart(String eventType) =>
      eventType == TugboatCollectorSessionEventType.sessionStart.wireValue;

  bool _isSessionEnd(String eventType) =>
      eventType == TugboatCollectorSessionEventType.sessionEnd.wireValue;

  void _applyLifecycleResponse(
    String eventType,
    String responseBody,
    String localSessionId,
  ) {
    final raw = responseBody.trim();
    if (raw.isEmpty) {
      _useLocalSessionIdForStart(eventType, localSessionId);
      return;
    }
    try {
      _applyDecodedLifecycleResponse(
        eventType,
        jsonDecode(raw) as Map<String, dynamic>,
        localSessionId,
      );
    } on Object {
      _useLocalSessionIdForStart(eventType, localSessionId);
    }
  }

  void _applyDecodedLifecycleResponse(
    String eventType,
    Map<String, dynamic> decoded,
    String localSessionId,
  ) {
    if (_isSessionStart(eventType)) {
      final serverId = decoded['sessionId'] as String?;
      _collectorSessionId = serverId != null && serverId.isNotEmpty
          ? serverId
          : localSessionId;
    }
    final responseTraitsId = decoded['traitsId'] as String?;
    if (responseTraitsId != null && responseTraitsId.isNotEmpty) {
      _traitsId = responseTraitsId;
    }
  }

  void _useLocalSessionIdForStart(String eventType, String localSessionId) {
    if (_isSessionStart(eventType)) _collectorSessionId ??= localSessionId;
  }

  /// The events lane: the retry head once, then fresh batches, stopping as
  /// soon as a response makes the lane wait. Unsent fresh events stay in
  /// the fresh queue (the engine's `flush_pass.cpp` does the same).
  Future<void> _flushEvents(int epoch) async {
    while (_retryBatches.isNotEmpty && !_eventsLaneWaiting) {
      final result = await _sendEventBatch(_retryBatches.first, epoch);
      if (!_isCurrentEpoch(epoch)) return;
      // Head-of-line: the retry head stays; fresh events still go out.
      if (result == _SendResult.retry) break;
      _retryBatches.removeAt(0);
    }
    while (_pendingEvents.isNotEmpty && !_eventsLaneWaiting) {
      await _flushEventBatch(epoch);
      if (!_isCurrentEpoch(epoch)) return;
    }
  }

  bool get _eventsLaneWaiting =>
      _laneDelays.isBlocked(CollectorDeliveryLane.events);

  Future<void> _flushEventBatch(int epoch) async {
    final count = _pendingEvents.length < _config.eventBatchSize
        ? _pendingEvents.length
        : _config.eventBatchSize;
    final batch = _pendingEvents.sublist(0, count);
    _pendingEvents.removeRange(0, count);

    final result = await _sendEventBatch(batch, epoch);
    if (!_isCurrentEpoch(epoch)) return;
    if (result == _SendResult.retry) {
      _enqueueRetryBatch(batch);
    }
  }

  void _enqueueRetryBatch(List<Map<String, Object?>> batch) {
    _retryBatches.add(batch);
    while (_retryBatches.length > _config.maxPendingBatches) {
      _retryBatches.removeAt(0);
    }
  }

  Future<_SendResult> _sendEventBatch(
    List<Map<String, Object?>> events,
    int epoch,
  ) async {
    final sessionId = _collectorSessionId;
    if (sessionId == null || sessionId.isEmpty) return _SendResult.retry;

    final traitsId = _traitsId;
    for (final event in events) {
      event['sessionId'] = sessionId;
      if (traitsId != null && traitsId.isNotEmpty) {
        event['traitsId'] = traitsId;
      }
    }

    final sent = await _collectorPost(
      CollectorDeliveryLane.events,
      '/v1/events/batch',
      (url) => _client.post(
        url,
        headers: _CollectorHttpClient._jsonHeaders,
        body: jsonEncode({'events': events}),
      ),
      epoch,
    );
    return sent.result;
  }

  /// One pass over the lanes in the engine's order. Each lane's
  /// `Retry-After` wait is checked once, where its stage starts; a waiting
  /// lane is skipped and the others still send.
  Future<void> _flushOnce() async {
    final epoch = _sessionEpoch;
    if (!_laneDelays.isBlocked(CollectorDeliveryLane.lifecycle)) {
      await _flushLifecyclePosts();
      if (!_isCurrentEpoch(epoch)) return;
    }
    // Never upload events or frames until the collector session id is known.
    if (!_hasCollectorSessionId) return;
    // Upload visual evidence before publishing events that reference frame IDs.
    // Session completion may trigger inspection as soon as those events arrive.
    if (!_laneDelays.isBlocked(CollectorDeliveryLane.frames)) {
      await _flushFrames();
      if (!_isCurrentEpoch(epoch)) return;
    }
    await _flushEvents(epoch);
  }

  /// One collector request to [path] on [lane]. Owns, for every lane, the
  /// send (to [path] resolved against the base URL), the session-epoch
  /// re-check after the response, and arming the lane's `Retry-After` wait.
  /// A response for an older session arms nothing and returns no response;
  /// callers re-check the epoch and drop it. Never throws: a failed send is
  /// a retry.
  Future<({_SendResult result, http.Response? response})> _collectorPost(
    CollectorDeliveryLane lane,
    String path,
    Future<http.Response> Function(Uri url) send,
    int epoch, {
    Duration? timeout,
  }) async {
    try {
      final traced = _tracedResponse(path, () => send(_baseUri.resolve(path)));
      final response = await (timeout == null
          ? traced
          : traced.timeout(timeout));
      if (!_isCurrentEpoch(epoch)) {
        return (result: _SendResult.retry, response: null);
      }
      _laneDelays.armFromResponse(
        lane,
        response.statusCode,
        response.headers,
        _now(),
        capMs: _retryAfterCapMs(lane),
      );
      return (
        result: _classifyResponse(response.statusCode),
        response: response,
      );
    } catch (_) {
      return (result: _SendResult.retry, response: null);
    }
  }

  void _trimPendingEvents() {
    if (_pendingEvents.length <= _config.maxPendingEvents) return;
    final dropped = _pendingEvents.length - _config.maxPendingEvents;
    _pendingEvents.removeRange(0, dropped);
    debugPrint(
      '[tugboat] collector dropped $dropped pending event(s) due to backpressure',
    );
  }

  _SendResult _classifyResponse(int statusCode) {
    if (statusCode == 202) return _SendResult.accepted;
    if (_shouldRetry(statusCode)) return _SendResult.retry;
    return _SendResult.drop;
  }

  bool _shouldRetry(int statusCode) =>
      statusCode == 408 || statusCode == 429 || statusCode >= 500;

  Future<http.Response> _tracedResponse(
    String path,
    Future<http.Response> Function() send,
  ) async {
    if (!_httpProofEnabled) return send();
    final stopwatch = Stopwatch()..start();
    try {
      final response = await send();
      _logHttpProof(
        path: path,
        statusCode: response.statusCode,
        durationMs: stopwatch.elapsedMilliseconds,
      );
      return response;
    } catch (error) {
      _logHttpProof(
        path: path,
        durationMs: stopwatch.elapsedMilliseconds,
        error: error,
      );
      rethrow;
    }
  }

  void _logHttpProof({
    required String path,
    int? statusCode,
    required int durationMs,
    Object? error,
  }) {
    debugPrint(
      formatCollectorHttpProofLine(
        path: path,
        localSessionId: _session?.id,
        returnedSessionId: _collectorSessionId,
        statusCode: statusCode,
        durationMs: durationMs,
        error: error,
      ),
    );
  }
}

enum _SendResult { accepted, retry, drop }

class _CollectorHttpClient extends http.BaseClient {
  _CollectorHttpClient({
    required http.Client inner,
    required String apiKey,
    required String platform,
    required String buildNumber,
    required String versionName,
    required String appId,
  }) : _inner = inner,
       _defaultHeaders = {
         'X-PMKit-API-Key': apiKey,
         'X-Tugboat-API-Key': apiKey,
         'X-Platform': platform,
         'X-App-Build': buildNumber,
         'X-App-Version': versionName,
         'X-App-Id': appId,
         'X-Sdk-Version': tugboatSdkVersion,
       };

  static const _jsonHeaders = {'Content-Type': 'application/json'};

  final http.Client _inner;
  final Map<String, String> _defaultHeaders;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    for (final entry in _defaultHeaders.entries) {
      request.headers.putIfAbsent(entry.key, () => entry.value);
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

class _PendingSessionLifecycle {
  const _PendingSessionLifecycle({
    required this.eventType,
    required this.triggeredAt,
    this.activeLocale,
  });

  final String eventType;
  final DateTime triggeredAt;
  final TugboatLocaleInfo? activeLocale;
}

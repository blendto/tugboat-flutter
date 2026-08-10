import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'capture_sink.dart';
import 'collector_config.dart';
import 'collector_mapper.dart';
import 'models.dart';
import 'sdk_version.dart';

/// Best-effort HTTP sink for the standalone `tugboat-collector` service.
class CollectorHttpSink implements TugboatCaptureSink {
  CollectorHttpSink({
    required TugboatCollectorConfig config,
    http.Client? client,
    Map<String, dynamic>? initialTraits,
    String? initialTraitsId,
    String? initialUserId,
    @visibleForTesting Duration? identityDebounceDuration,
  }) : _config = config,
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
       );

  final TugboatCollectorConfig _config;
  final _CollectorHttpClient _client;

  bool _disposed = false;
  TugboatSession? _session;

  /// Collector-issued id; null until session_start is accepted.
  String? _collectorSessionId;
  int _sessionEpoch = 0;
  Timer? _flushTimer;
  Future<void>? _flushInFlight;
  bool _framesNeedRetry = false;
  final List<Map<String, Object?>> _pendingEvents = [];
  final List<_PendingFrameUpload> _pendingFrames = [];
  final List<List<Map<String, Object?>>> _retryBatches = [];
  final List<_PendingSessionLifecycle> _pendingLifecycle = [];

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
    _cancelIdentityDebounce();
    _userDirty = false;
    _traitsDirty = false;
    _userTriggeredAt = null;
    _traitsTriggeredAt = null;
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
    });
    _flushInFlight = operation;
    return operation;
  }

  /// Wait for any in-flight flush, then run another so newly enqueued work is sent.
  Future<void> _kickFlush() async {
    final active = _flushInFlight;
    if (active != null) await active;
    if (_disposed) return;
    await flush();
  }

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
    _traitsTriggeredAt = DateTime.now();
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
    _userTriggeredAt = DateTime.now();
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
    if (_userDirty && _traitsDirty) {
      final userAt = _userTriggeredAt;
      final traitsAt = _traitsTriggeredAt;
      if (userAt != null && traitsAt != null) {
        return userAt.isAfter(traitsAt) ? userAt : traitsAt;
      }
      return userAt ?? traitsAt ?? DateTime.now();
    }
    if (_userDirty) return _userTriggeredAt ?? DateTime.now();
    return _traitsTriggeredAt ?? DateTime.now();
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
    await _flushIdentityDebounce();
    await flush();
    _enqueueSessionLifecycle(
      TugboatCollectorSessionEventType.sessionEnd.wireValue,
      DateTime.now(),
    );
    await _drainLifecyclePosts();
    _cancelFlushTimer();
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
      _PendingSessionLifecycle(eventType: eventType, triggeredAt: triggeredAt),
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

  Future<void> _flushLifecyclePosts() async {
    if (_pendingLifecycle.isEmpty || _disposed) return;
    final pending = _pendingLifecycle.first;
    final epoch = _sessionEpoch;

    final result = await _sendSessionLifecycle(
      pending.eventType,
      pending.triggeredAt,
      epoch,
    );
    if (!_isCurrentEpoch(epoch)) return;
    if (result == _SendResult.accepted) {
      _pendingLifecycle.removeAt(0);
    }
  }

  Future<_SendResult> _sendSessionLifecycle(
    String eventType,
    DateTime triggeredAt,
    int epoch,
  ) async {
    if (!_isCurrentEpoch(epoch)) return _SendResult.drop;
    final session = _session;
    if (session == null) return _SendResult.accepted;

    // session_start uses the local id; later lifecycle uses the collector id when known.
    final sessionId =
        eventType == TugboatCollectorSessionEventType.sessionStart.wireValue
        ? session.id
        : (_collectorSessionId ?? session.id);

    final includeFullTraits =
        _traits != null &&
        (eventType == TugboatCollectorSessionEventType.sessionStart.wireValue ||
            eventType ==
                TugboatCollectorSessionEventType.sessionIdentify.wireValue ||
            eventType ==
                TugboatCollectorSessionEventType.traitsUpdated.wireValue ||
            eventType ==
                TugboatCollectorSessionEventType.userChanged.wireValue);

    final body = mapTugboatSessionLifecycleToCollectorSession(
      eventType: eventType,
      sessionId: sessionId,
      triggeredAt: triggeredAt,
      config: _config,
      userId: _userId,
      traits: includeFullTraits ? _traits : null,
      traitsId: includeFullTraits ? null : _traitsId,
    );

    try {
      final response = await _client.post(
        _baseUri.resolve('/v1/sessions'),
        headers: _CollectorHttpClient._jsonHeaders,
        body: jsonEncode(body),
      );

      final result = _classifyResponse(response.statusCode);
      // Status alone decides acceptance (same as events/frames). Body is
      // optional enrichment; empty or non-JSON must not turn 202 into retry.
      if (result == _SendResult.accepted && _isCurrentEpoch(epoch)) {
        final raw = response.body.trim();
        if (raw.isEmpty) {
          if (eventType ==
              TugboatCollectorSessionEventType.sessionStart.wireValue) {
            _collectorSessionId ??= session.id;
          }
        } else {
          try {
            final decoded = jsonDecode(raw) as Map<String, dynamic>;
            if (eventType ==
                TugboatCollectorSessionEventType.sessionStart.wireValue) {
              final serverId = decoded['sessionId'] as String?;
              _collectorSessionId = (serverId != null && serverId.isNotEmpty)
                  ? serverId
                  : session.id;
            }
            final responseTraitsId = decoded['traitsId'] as String?;
            if (responseTraitsId != null && responseTraitsId.isNotEmpty) {
              _traitsId = responseTraitsId;
            }
          } on Object {
            if (eventType ==
                TugboatCollectorSessionEventType.sessionStart.wireValue) {
              _collectorSessionId ??= session.id;
            }
          }
        }
      }
      return result;
    } catch (_) {
      return _SendResult.retry;
    }
  }

  Future<void> _flushEventBatch() async {
    if (_pendingEvents.isEmpty) return;
    final epoch = _sessionEpoch;

    final count = _pendingEvents.length < _config.eventBatchSize
        ? _pendingEvents.length
        : _config.eventBatchSize;
    final batch = _pendingEvents.sublist(0, count);
    _pendingEvents.removeRange(0, count);

    final result = await _sendEventBatch(batch, epoch: epoch);
    if (!_isCurrentEpoch(epoch)) return;
    if (result == _SendResult.retry) {
      _enqueueRetryBatch(batch);
    }
  }

  Future<void> _flushRetryBatches() async {
    final epoch = _sessionEpoch;
    while (_retryBatches.isNotEmpty) {
      final result = await _sendEventBatch(_retryBatches.first, epoch: epoch);
      if (!_isCurrentEpoch(epoch)) return;
      if (result == _SendResult.retry) return;
      _retryBatches.removeAt(0);
    }
  }

  void _enqueueRetryBatch(List<Map<String, Object?>> batch) {
    _retryBatches.add(batch);
    while (_retryBatches.length > _config.maxPendingBatches) {
      _retryBatches.removeAt(0);
    }
  }

  Future<_SendResult> _sendEventBatch(
    List<Map<String, Object?>> events, {
    required int epoch,
  }) async {
    if (events.isEmpty) return _SendResult.accepted;
    if (!_isCurrentEpoch(epoch)) return _SendResult.drop;

    final sessionId = _collectorSessionId;
    if (sessionId == null || sessionId.isEmpty) return _SendResult.retry;
    final traitsId = _traitsId;
    for (final event in events) {
      event['sessionId'] = sessionId;
      if (traitsId != null && traitsId.isNotEmpty) {
        event['traitsId'] = traitsId;
      }
    }

    try {
      final response = await _client.post(
        _baseUri.resolve('/v1/events/batch'),
        headers: _CollectorHttpClient._jsonHeaders,
        body: jsonEncode({'events': events}),
      );

      return _classifyResponse(response.statusCode);
    } catch (_) {
      return _SendResult.retry;
    }
  }

  Future<void> _flushOnce() async {
    final epoch = _sessionEpoch;
    await _flushLifecyclePosts();
    if (!_isCurrentEpoch(epoch)) return;
    // Never upload events or frames until the collector session id is known.
    if (!_hasCollectorSessionId) {
      return;
    }
    if (_retryBatches.isNotEmpty) {
      // Try the retry head once, but keep draining fresh events below.
      await _flushRetryBatches();
    }
    while (_pendingEvents.isNotEmpty) {
      await _flushEventBatch();
    }
    await _flushFrames();
  }

  Future<void> _flushFrames() async {
    if (_pendingFrames.isEmpty) return;
    final epoch = _sessionEpoch;
    final sessionId = _collectorSessionId;
    // Confirm the current collector session before draining so frames queued
    // for a newer session cannot be cleared by a stale in-flight flush.
    if (sessionId == null || sessionId.isEmpty || !_isCurrentEpoch(epoch)) {
      return;
    }

    final uploads = List<_PendingFrameUpload>.from(_pendingFrames)
      ..sort((a, b) => a.frameNo.compareTo(b.frameNo));
    _pendingFrames.clear();

    // Drop extracted uploads when the session was reset mid-flush rather than
    // sending them under a stale collector id.
    if (!_isCurrentEpoch(epoch)) {
      return;
    }
    final request = http.MultipartRequest(
      'POST',
      _baseUri.resolve('/v1/frames'),
    );
    request.fields['sessionId'] = sessionId;
    request.fields['frameNos'] = uploads
        .map((upload) => upload.frameNo.toString())
        .join(',');

    for (final upload in uploads) {
      request.files.add(
        http.MultipartFile.fromBytes(
          'files',
          upload.bytes,
          filename: '${upload.frameNo}.jpg',
          contentType: MediaType('image', 'jpeg'),
        ),
      );
    }

    try {
      final streamed = await _client.send(request);
      final response = await http.Response.fromStream(streamed);
      if (!_isCurrentEpoch(epoch)) return;
      final result = _classifyResponse(response.statusCode);
      _framesNeedRetry = result == _SendResult.retry;
      if (_framesNeedRetry) {
        _requeueFailedUploads(uploads);
      }
    } catch (_) {
      if (!_isCurrentEpoch(epoch)) return;
      _framesNeedRetry = true;
      _requeueFailedUploads(uploads);
    }
  }

  void _requeueFailedUploads(List<_PendingFrameUpload> uploads) {
    // Events reference exact frame IDs; never drop uploads on retry.
    _pendingFrames.insertAll(0, uploads);
    _trimPendingFrames();
  }

  void _trimPendingEvents() {
    if (_pendingEvents.length <= _config.maxPendingEvents) return;
    final dropped = _pendingEvents.length - _config.maxPendingEvents;
    _pendingEvents.removeRange(0, dropped);
    debugPrint(
      '[tugboat] collector dropped $dropped pending event(s) due to backpressure',
    );
  }

  void _trimPendingFrames() {
    if (_pendingFrames.length <= _config.maxPendingFrames) return;
    final dropped = _pendingFrames.length - _config.maxPendingFrames;
    _pendingFrames.removeRange(0, dropped);
    debugPrint(
      '[tugboat] collector dropped $dropped pending frame(s) due to backpressure',
    );
  }

  _SendResult _classifyResponse(int statusCode) {
    if (statusCode == 202) return _SendResult.accepted;
    if (_shouldRetry(statusCode)) return _SendResult.retry;
    return _SendResult.drop;
  }

  bool _shouldRetry(int statusCode) =>
      statusCode == 408 || statusCode == 429 || statusCode >= 500;
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
  });

  final String eventType;
  final DateTime triggeredAt;
}

class _PendingFrameUpload {
  const _PendingFrameUpload({
    required this.frameNo,
    required this.bytes,
  });

  final int frameNo;
  final Uint8List bytes;
}

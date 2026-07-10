import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'capture_sink.dart';
import 'collector_config.dart';
import 'collector_mapper.dart';
import 'models.dart';

/// Best-effort HTTP sink for the standalone `tugboat-collector` service.
class CollectorHttpSink implements TugboatCaptureSink {
  CollectorHttpSink({
    required TugboatCollectorConfig config,
    http.Client? client,
  }) : _config = config,
       _client = _CollectorHttpClient(
         inner: client ?? http.Client(),
         apiKey: config.apiKey,
         platform: config.deviceInfo.platform,
         buildNumber: config.appInfo.buildNumber,
         versionName: config.appInfo.version,
       );

  final TugboatCollectorConfig _config;
  final _CollectorHttpClient _client;

  bool _disposed = false;
  TugboatSession? _session;
  String? _collectorSessionId;
  Timer? _flushTimer;
  Future<void>? _flushInFlight;
  bool _framesNeedRetry = false;
  final List<Map<String, Object?>> _pendingEvents = [];
  final List<_PendingFrameUpload> _pendingFrames = [];
  final List<List<Map<String, Object?>>> _retryBatches = [];
  _PendingSessionLifecycle? _pendingLifecycle;
  _PendingSessionLifecycle? _pendingLifecycleTail;

  Uri get _baseUri => Uri.parse(_config.baseUrl.replaceAll(RegExp(r'/+$'), ''));

  @override
  void startSession(TugboatSession session) {
    if (_disposed) return;
    _session = session;
    _collectorSessionId = session.id;
    _scheduleFlushTimer();
    _enqueueSessionLifecycle('session_start', session.startedAt);
    unawaited(_flushLifecyclePosts());
  }

  @override
  void recordEvent(TugboatEvent event) {
    if (_disposed || _session == null) return;
    if (event.type == 'session_start' || event.type == 'session_end') {
      // Lifecycle is sent through POST /v1/sessions.
      return;
    }

    final session = _session!;
    _pendingEvents.add(
      mapTugboatEventToCollectorEvent(
        event: event,
        sessionId: _collectorSessionId ?? session.id,
        sessionStartedAt: session.startedAt,
        userId: _config.userId,
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
    _pendingFrames.add(
      _PendingFrameUpload(
        frameNo: frameNumberFromId(frame.id),
        bytes: bytes,
        sessionId: _collectorSessionId ?? sessionId,
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

  @override
  Future<void> endSession() async {
    if (_disposed || _session == null) return;
    await flush();
    _enqueueSessionLifecycle('session_end', DateTime.now());
    await _drainLifecyclePosts();
    _cancelFlushTimer();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelFlushTimer();
    _client.close();
    _pendingEvents.clear();
    _pendingFrames.clear();
    _retryBatches.clear();
    _pendingLifecycle = null;
    _pendingLifecycleTail = null;
    _flushInFlight = null;
    _session = null;
  }

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
    final post = _PendingSessionLifecycle(
      eventType: eventType,
      triggeredAt: triggeredAt,
    );
    if (_pendingLifecycle == null) {
      _pendingLifecycle = post;
      return;
    }
    _pendingLifecycleTail = post;
  }

  Future<void> _drainLifecyclePosts() async {
    while (!_disposed &&
        (_pendingLifecycle != null || _pendingLifecycleTail != null)) {
      await _flushLifecyclePosts();
      if (_pendingLifecycle != null) return;
    }
  }

  Future<void> _flushLifecyclePosts() async {
    final pending = _pendingLifecycle;
    if (pending == null || _disposed) return;

    final result = await _sendSessionLifecycle(
      pending.eventType,
      pending.triggeredAt,
    );
    if (_disposed) return;
    if (result == _SendResult.accepted) {
      _pendingLifecycle = _pendingLifecycleTail;
      _pendingLifecycleTail = null;
    }
  }

  Future<_SendResult> _sendSessionLifecycle(
    String eventType,
    DateTime triggeredAt,
  ) async {
    final session = _session;
    if (session == null) return _SendResult.accepted;

    final body = mapTugboatSessionLifecycleToCollectorSession(
      eventType: eventType,
      sessionId: _collectorSessionId ?? session.id,
      triggeredAt: triggeredAt,
      config: _config,
      userId: _config.userId,
    );

    try {
      final response = await _client.post(
        _baseUri.resolve('/v1/sessions'),
        headers: _CollectorHttpClient._jsonHeaders,
        body: jsonEncode(body),
      );

      final result = _classifyResponse(response.statusCode);
      if (result == _SendResult.accepted) {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final sessionId = decoded['sessionId'] as String?;
        if (sessionId != null && sessionId.isNotEmpty) {
          _collectorSessionId = sessionId;
        }
      }
      return result;
    } catch (_) {
      return _SendResult.retry;
    }
  }

  Future<void> _flushEventBatch() async {
    if (_pendingEvents.isEmpty) return;

    final count = _pendingEvents.length < _config.eventBatchSize
        ? _pendingEvents.length
        : _config.eventBatchSize;
    final batch = _pendingEvents.sublist(0, count);
    _pendingEvents.removeRange(0, count);

    final result = await _sendEventBatch(batch);
    if (_disposed) return;
    if (result == _SendResult.retry) {
      _enqueueRetryBatch(batch);
    }
  }

  Future<void> _flushRetryBatches() async {
    while (_retryBatches.isNotEmpty) {
      final result = await _sendEventBatch(_retryBatches.first);
      if (_disposed) return;
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

  Future<_SendResult> _sendEventBatch(List<Map<String, Object?>> events) async {
    if (events.isEmpty) return _SendResult.accepted;

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
    await _flushLifecyclePosts();
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

    final uploads = List<_PendingFrameUpload>.from(_pendingFrames);
    _pendingFrames.clear();

    final request = http.MultipartRequest(
      'POST',
      _baseUri.resolve('/v1/frames'),
    );
    request.fields['sessionId'] = uploads.first.sessionId;
    request.fields['frameNos'] = uploads
        .map((upload) => upload.frameNo.toString())
        .join(',');

    for (final upload in uploads) {
      request.files.add(
        http.MultipartFile.fromBytes(
          'files',
          upload.bytes,
          filename: '${upload.frameNo}.png',
          contentType: MediaType('image', 'png'),
        ),
      );
    }

    try {
      final streamed = await _client.send(request);
      final response = await http.Response.fromStream(streamed);
      if (_disposed) return;
      final result = _classifyResponse(response.statusCode);
      _framesNeedRetry = result == _SendResult.retry;
      if (_framesNeedRetry) {
        _pendingFrames.insertAll(0, uploads);
        _trimPendingFrames();
      }
    } catch (_) {
      if (_disposed) return;
      _framesNeedRetry = true;
      _pendingFrames.insertAll(0, uploads);
      _trimPendingFrames();
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
  }) : _inner = inner,
       _defaultHeaders = {
         'X-PMKit-API-Key': apiKey,
         'X-Tugboat-API-Key': apiKey,
         'X-Platform': platform,
         'X-App-Build': buildNumber,
         'X-App-Version': versionName,
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
    required this.sessionId,
  });

  final int frameNo;
  final Uint8List bytes;
  final String sessionId;
}

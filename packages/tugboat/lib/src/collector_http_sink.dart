import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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
       );

  final TugboatCollectorConfig _config;
  final _CollectorHttpClient _client;

  bool _disposed = false;
  TugboatSession? _session;
  String? _collectorSessionId;
  Timer? _flushTimer;
  final List<Map<String, Object?>> _pendingEvents = [];
  final List<_PendingFrameUpload> _pendingFrames = [];
  final List<List<Map<String, Object?>>> _retryBatches = [];

  Uri get _baseUri => Uri.parse(_config.baseUrl.replaceAll(RegExp(r'/+$'), ''));

  @override
  void startSession(TugboatSession session) {
    if (_disposed) return;
    _session = session;
    _collectorSessionId = session.id;
    _scheduleFlushTimer();
    unawaited(_postSessionLifecycle('session_start', session.startedAt));
  }

  @override
  void recordEvent(TugboatEvent event) {
    if (_disposed || _session == null) return;
    if (event.type == 'session_start') {
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
    unawaited(_flushFrames());
  }

  @override
  Future<void> flush() async {
    if (_disposed) return;
    await _flushEventBatch();
    await _flushFrames();
    await _flushRetryBatches();
  }

  @override
  Future<void> endSession() async {
    if (_disposed || _session == null) return;
    await flush();
    await _postSessionLifecycle('session_end', DateTime.now());
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

  Future<void> _postSessionLifecycle(
    String eventType,
    DateTime triggeredAt,
  ) async {
    final session = _session;
    if (session == null) return;

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

      if (_shouldRetry(response.statusCode)) {
        return;
      }

      if (response.statusCode == 202) {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final sessionId = decoded['sessionId'] as String?;
        if (sessionId != null && sessionId.isNotEmpty) {
          _collectorSessionId = sessionId;
        }
      }
    } catch (_) {
      // Best-effort ingestion only.
    }
  }

  Future<void> _flushEventBatch() async {
    if (_pendingEvents.isEmpty) return;

    final batch = List<Map<String, Object?>>.from(_pendingEvents);
    _pendingEvents.clear();

    final success = await _sendEventBatch(batch);
    if (!success) {
      _enqueueRetryBatch(batch);
    }
  }

  Future<void> _flushRetryBatches() async {
    if (_retryBatches.isEmpty) return;

    final remaining = <List<Map<String, Object?>>>[];
    for (final batch in _retryBatches) {
      final success = await _sendEventBatch(batch);
      if (!success) {
        remaining.add(batch);
      }
    }
    _retryBatches
      ..clear()
      ..addAll(remaining);
  }

  void _enqueueRetryBatch(List<Map<String, Object?>> batch) {
    _retryBatches.add(batch);
    while (_retryBatches.length > _config.maxPendingBatches) {
      _retryBatches.removeAt(0);
    }
  }

  Future<bool> _sendEventBatch(List<Map<String, Object?>> events) async {
    if (events.isEmpty) return true;

    try {
      final response = await _client.post(
        _baseUri.resolve('/v1/events/batch'),
        headers: _CollectorHttpClient._jsonHeaders,
        body: jsonEncode({'events': events}),
      );

      if (_shouldRetry(response.statusCode)) {
        return false;
      }

      return response.statusCode == 202;
    } catch (_) {
      return false;
    }
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
      if (_shouldRetry(response.statusCode)) {
        _pendingFrames.insertAll(0, uploads);
      }
    } catch (_) {
      _pendingFrames.insertAll(0, uploads);
      while (_pendingFrames.length > _config.maxPendingBatches * 10) {
        _pendingFrames.removeAt(0);
      }
    }
  }

  bool _shouldRetry(int statusCode) => statusCode == 503 || statusCode == 429;
}

class _CollectorHttpClient extends http.BaseClient {
  _CollectorHttpClient({required http.Client inner, required String apiKey})
    : _inner = inner,
      _defaultHeaders = {
        'X-PMKit-API-Key': apiKey,
        'X-Tugboat-API-Key': apiKey,
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

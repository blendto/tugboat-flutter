part of 'collector_http_sink.dart';

/// The frames lane of [CollectorHttpSink]: `POST /v1/frames` uploads, 400
/// isolation, requeue on retry, and the upload diagnostics.
extension _CollectorFrameUploads on CollectorHttpSink {
  /// Uploads every pending frame in frame-number order, [_frameChunk] per
  /// request. The caller checks the frames lane is not waiting.
  Future<void> _flushFrames() async {
    final sessionId = _collectorSessionId;
    // Confirm the current collector session before draining so frames queued
    // for a newer session cannot be cleared by a stale in-flight flush.
    if (_pendingFrames.isEmpty || sessionId == null || sessionId.isEmpty) {
      return;
    }
    final uploads = List<_PendingFrameUpload>.from(_pendingFrames)
      ..sort((a, b) => a.frameNo.compareTo(b.frameNo));
    _pendingFrames.clear();

    final dropped = await _uploadFrameChunks(sessionId, uploads, _sessionEpoch);
    if (dropped == null) return;
    _framesNeedRetry = false;
    if (_frameUploadFailureReported && !dropped) {
      _recordUploadDiagnostic('recovered', null, 0);
      _frameUploadFailureReported = false;
    }
  }

  /// Sends [uploads] chunk by chunk. Returns whether any chunk was dropped,
  /// or null when the pass stopped early: a retry outcome requeued that
  /// chunk and every later one, or the session changed.
  Future<bool?> _uploadFrameChunks(
    String sessionId,
    List<_PendingFrameUpload> uploads,
    int epoch,
  ) async {
    var droppedBatch = false;
    for (var start = 0; start < uploads.length; start += _frameChunk) {
      final end = start + _frameChunk < uploads.length
          ? start + _frameChunk
          : uploads.length;
      final batch = uploads.sublist(start, end);
      final result = await _processFrameBatch(sessionId, batch, epoch);
      if (!_isCurrentEpoch(epoch)) return null;
      if (result.retry) {
        _framesNeedRetry = true;
        _requeueFailedUploads(uploads.sublist(start + result.retryOffset));
        return null;
      }
      droppedBatch = droppedBatch || result.dropped;
    }
    return droppedBatch;
  }

  Future<({bool retry, bool dropped, int retryOffset})> _processFrameBatch(
    String sessionId,
    List<_PendingFrameUpload> batch,
    int epoch,
  ) async {
    final result = await _sendFrameBatch(sessionId, batch, epoch);
    if (!_isCurrentEpoch(epoch)) {
      return (retry: false, dropped: false, retryOffset: 0);
    }
    if (result.result == _SendResult.retry) {
      _reportFrameUploadFailure(result.statusCode, batch.length);
      return (retry: true, dropped: false, retryOffset: 0);
    }
    if (result.result == _SendResult.drop &&
        result.statusCode == 400 &&
        batch.length > 1) {
      _reportFrameUploadFailure(result.statusCode, batch.length);
      return _isolateRejectedFrames(sessionId, batch, epoch);
    }
    if (result.result == _SendResult.drop) {
      _reportFrameUploadFailure(result.statusCode, batch.length);
      return (retry: false, dropped: true, retryOffset: 0);
    }
    return (retry: false, dropped: false, retryOffset: 0);
  }

  Future<({bool retry, bool dropped, int retryOffset})> _isolateRejectedFrames(
    String sessionId,
    List<_PendingFrameUpload> batch,
    int epoch,
  ) async {
    var dropped = false;
    // A single invalid capture must not discard its valid neighbors.
    for (var index = 0; index < batch.length; index++) {
      final result = await _sendFrameBatch(sessionId, [batch[index]], epoch);
      if (!_isCurrentEpoch(epoch)) break;
      if (result.result == _SendResult.retry) {
        _reportFrameUploadFailure(result.statusCode, 1);
        return (retry: true, dropped: dropped, retryOffset: index);
      }
      if (result.result == _SendResult.drop) {
        dropped = true;
        _reportFrameUploadFailure(result.statusCode, 1);
      }
    }
    return (retry: false, dropped: dropped, retryOffset: 0);
  }

  Future<({_SendResult result, int? statusCode})> _sendFrameBatch(
    String sessionId,
    List<_PendingFrameUpload> uploads,
    int epoch,
  ) async {
    final sent = await _collectorPost(
      CollectorDeliveryLane.frames,
      '/v1/frames',
      () async => http.Response.fromStream(
        await _client.send(_frameUploadRequest(sessionId, uploads)),
      ),
      epoch,
      timeout: _frameUploadTimeout,
    );
    return (result: sent.result, statusCode: sent.response?.statusCode);
  }

  http.MultipartRequest _frameUploadRequest(
    String sessionId,
    List<_PendingFrameUpload> uploads,
  ) {
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
    request.fields['frameMetadata'] = jsonEncode(
      uploads.map((upload) => upload.metadata).toList(),
    );
    return request;
  }

  void _reportFrameUploadFailure(int? statusCode, int frameCount) {
    if (_frameUploadFailureReported) return;
    _frameUploadFailureReported = true;
    _recordUploadDiagnostic('failed', statusCode, frameCount);
  }

  void _recordUploadDiagnostic(String result, int? statusCode, int frameCount) {
    final session = _session;
    if (session == null) return;
    final event = TugboatEvent(
      id: 'collector-frame-upload-${_frameUploadDiagnosticSequence++}',
      atMs: _now().difference(session.startedAt).inMilliseconds,
      type: 'capture_diagnostic',
      data: {
        'component': 'collector_frame_upload',
        'result': result,
        if (statusCode != null) 'statusCode': statusCode,
        'frameCount': frameCount,
        'droppedFrameCount': _droppedFrameCount,
      },
    );
    _pendingEvents.add(
      mapTugboatEventToCollectorEvent(
        event: event,
        sessionStartedAt: session.startedAt,
        collectorConfig: _config,
        userId: _userId,
      ),
    );
    _trimPendingEvents();
  }

  void _requeueFailedUploads(List<_PendingFrameUpload> uploads) {
    // Keep failed uploads within the configured memory bound. Diagnostics
    // record any evictions so downstream consumers can see the evidence gap.
    _pendingFrames.insertAll(0, uploads);
    _trimPendingFrames();
  }

  void _trimPendingFrames() {
    if (_pendingFrames.length <= _config.maxPendingFrames) return;
    final dropped = _pendingFrames.length - _config.maxPendingFrames;
    _pendingFrames.removeRange(0, dropped);
    _droppedFrameCount += dropped;
    if (_droppedFrameCount == 1 ||
        (_droppedFrameCount & (_droppedFrameCount - 1)) == 0) {
      _recordUploadDiagnostic('dropped', null, _droppedFrameCount);
    }
    debugPrint(
      '[tugboat] collector dropped $dropped pending frame(s) due to backpressure',
    );
  }
}

/// Frames per `POST /v1/frames` (the engine's `collector.frameChunk`).
const _frameChunk = 20;

/// Frame uploads time out; JSON posts do not (change C3).
const _frameUploadTimeout = Duration(seconds: 15);

class _PendingFrameUpload {
  const _PendingFrameUpload({
    required this.frameNo,
    required this.bytes,
    required this.metadata,
  });

  final int frameNo;
  final Uint8List bytes;
  final Map<String, Object?> metadata;
}

import 'dart:convert';
import 'dart:typed_data';

import '../capture_sink.dart';
import '../models.dart';
import 'outbox.dart';

/// Wraps [CollectorHttpSink] with opt-in durable append-before-send.
class OutboxBackedCaptureSink implements TugboatCaptureSink {
  OutboxBackedCaptureSink({
    required TugboatCaptureSink inner,
    required TugboatOutboxStore store,
  }) : _inner = inner,
       _store = store;

  final TugboatCaptureSink _inner;
  final TugboatOutboxStore _store;
  TugboatSession? _session;

  @override
  void startSession(TugboatSession session) {
    _session = session;
    _inner.startSession(session);
    // ignore: discarded_futures
    _store.load().then((_) => _replayPending());
  }

  @override
  void recordEvent(TugboatEvent event) {
    final session = _session;
    if (session != null &&
        event.type != 'session_start' &&
        event.type != 'session_end') {
      final payload = event.toJson();
      // Strip any accidental free-text fields beyond the sanitized event model.
      final body = jsonEncode(payload);
      final key = tugboatOutboxIdempotencyKey(
        kind: 'event',
        captureSessionId: session.id,
        body: body,
      );
      // ignore: discarded_futures
      _store.append(
        TugboatOutboxEnvelope(
          idempotencyKey: key,
          kind: 'event',
          captureSessionId: session.id,
          activationRequestId: session.activationRequestId,
          payloadJson: payload,
          createdAt: DateTime.now().toUtc(),
        ),
      );
    }
    _inner.recordEvent(event);
  }

  @override
  void recordFrame(
    TugboatFrame frame,
    Uint8List bytes, {
    required String sessionId,
    String? actionId,
  }) {
    final session = _session;
    if (session != null) {
      final meta = {
        ...frame.toJson(),
        'byteLength': bytes.length,
        if (actionId != null) 'actionId': actionId,
      };
      final key = tugboatOutboxIdempotencyKey(
        kind: 'frame',
        captureSessionId: sessionId,
        body: '${frame.id}:${frame.contentHash}',
      );
      // ignore: discarded_futures
      _store.append(
        TugboatOutboxEnvelope(
          idempotencyKey: key,
          kind: 'frame',
          captureSessionId: sessionId,
          activationRequestId: session.activationRequestId,
          payloadJson: meta,
          payloadBytes: bytes,
          createdAt: DateTime.now().toUtc(),
        ),
      );
    }
    _inner.recordFrame(frame, bytes, sessionId: sessionId, actionId: actionId);
  }

  @override
  Future<void> flush() async {
    await _inner.flush();
    // Acknowledge drained live traffic best-effort by clearing matching keys
    // after a successful flush. Full per-batch ack lands with collector support.
    for (final entry in List<TugboatOutboxEnvelope>.from(_store.pending())) {
      await _store.acknowledge(entry.idempotencyKey);
    }
  }

  @override
  Future<void> endSession() async {
    await flush();
    await _inner.endSession();
  }

  @override
  void dispose() {
    _inner.dispose();
  }

  Future<void> _replayPending() async {
    // Restart recovery: re-drive pending envelopes through the inner sink.
    for (final entry in _store.pending()) {
      entry.attemptCount += 1;
      if (entry.kind == 'event') {
        try {
          final event = TugboatEvent(
            id: entry.payloadJson['id'] as String? ?? entry.idempotencyKey,
            atMs: entry.payloadJson['atMs'] as int? ?? 0,
            type: entry.payloadJson['type'] as String? ?? 'unknown',
            sessionId: entry.captureSessionId,
            captureSessionId: entry.captureSessionId,
            activationRequestId: entry.activationRequestId,
            data: Map<String, Object?>.from(
              entry.payloadJson['data'] as Map? ?? {},
            ),
            explorationRunId: entry.payloadJson['explorationRunId'] as String?,
            actionId: entry.payloadJson['actionId'] as String?,
          );
          _inner.recordEvent(event);
        } catch (_) {}
      } else if (entry.kind == 'frame' && entry.payloadBytes != null) {
        try {
          final frame = TugboatFrame(
            id: entry.payloadJson['id'] as String? ?? entry.idempotencyKey,
            atMs: entry.payloadJson['atMs'] as int? ?? 0,
            width: entry.payloadJson['width'] as int? ?? 0,
            height: entry.payloadJson['height'] as int? ?? 0,
            contentHash: entry.payloadJson['contentHash'] as String? ?? '',
            masked: entry.payloadJson['masked'] as bool? ?? true,
            byteLength: entry.payloadBytes!.length,
            captureSessionId: entry.captureSessionId,
          );
          _inner.recordFrame(
            frame,
            entry.payloadBytes!,
            sessionId: entry.captureSessionId,
            actionId: entry.payloadJson['actionId'] as String?,
          );
        } catch (_) {}
      }
    }
    await _inner.flush();
  }
}

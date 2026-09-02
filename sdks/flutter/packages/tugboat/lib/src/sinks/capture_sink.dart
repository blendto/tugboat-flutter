import 'dart:async';
import 'dart:typed_data';

import '../models.dart';

/// Context provided to sink factories for one emitted capture session.
class TugboatSinkSessionContext {
  const TugboatSinkSessionContext({
    required this.captureSessionId,
    required this.sessionEpoch,
    this.activationRequestId,
    this.explorationRunId,
  });

  final String captureSessionId;
  final int sessionEpoch;
  final String? activationRequestId;
  final String? explorationRunId;
}

/// Immutable delivery unit for sink mailboxes.
class TugboatCaptureEnvelope {
  const TugboatCaptureEnvelope({
    required this.kind,
    required this.captureSessionId,
    required this.sessionEpoch,
    required this.idempotencyKey,
    this.activationRequestId,
    this.event,
    this.frame,
    this.frameBytes,
    this.actionId,
    this.createdAt,
  });

  final TugboatEnvelopeKind kind;
  final String captureSessionId;
  final int sessionEpoch;
  final String idempotencyKey;
  final String? activationRequestId;
  final TugboatEvent? event;
  final TugboatFrame? frame;
  final Uint8List? frameBytes;
  final String? actionId;
  final DateTime? createdAt;
}

enum TugboatEnvelopeKind { sessionStart, event, frame, sessionEnd }

/// Session-owned destination. Must not throw or block the host app.
abstract class TugboatSessionCaptureSink {
  Future<void> start(TugboatSinkSessionContext context);

  void accept(TugboatCaptureEnvelope envelope);

  Future<void> flush();

  Future<void> finish();

  Future<void> dispose();
}

/// Legacy adapter matching the pre-factory sink surface.
abstract class TugboatLegacyCaptureSink {
  void startSession(TugboatSession session);

  void recordEvent(TugboatEvent event);

  void recordFrame(
    TugboatFrame frame,
    Uint8List bytes, {
    required String sessionId,
    String? actionId,
  });

  Future<void> flush();

  Future<void> endSession();

  void dispose();
}

/// Creates one sink instance per emitted capture session.
abstract class TugboatCaptureSinkFactory {
  TugboatSessionCaptureSink create(TugboatSinkSessionContext context);
}

/// Adapts a [TugboatLegacyCaptureSink] to the session-owned factory contract.
class LegacyCaptureSinkAdapter implements TugboatSessionCaptureSink {
  LegacyCaptureSinkAdapter(this._legacy, {required this.session});

  final TugboatLegacyCaptureSink _legacy;
  final TugboatSession session;
  bool _finished = false;

  @override
  Future<void> start(TugboatSinkSessionContext context) async {
    _legacy.startSession(session);
  }

  @override
  void accept(TugboatCaptureEnvelope envelope) {
    if (_finished) return;
    switch (envelope.kind) {
      case TugboatEnvelopeKind.sessionStart:
        break;
      case TugboatEnvelopeKind.event:
        final event = envelope.event;
        if (event != null) _legacy.recordEvent(event);
      case TugboatEnvelopeKind.frame:
        final frame = envelope.frame;
        final bytes = envelope.frameBytes;
        if (frame != null && bytes != null) {
          _legacy.recordFrame(
            frame,
            bytes,
            sessionId: envelope.captureSessionId,
            actionId: envelope.actionId,
          );
        }
      case TugboatEnvelopeKind.sessionEnd:
        break;
    }
  }

  @override
  Future<void> flush() => _legacy.flush();

  @override
  Future<void> finish() async {
    if (_finished) return;
    _finished = true;
    await _legacy.endSession();
  }

  @override
  Future<void> dispose() async {
    _legacy.dispose();
  }
}

/// Per-sink bounded mailbox with session-epoch fencing.
class TugboatSinkMailbox {
  TugboatSinkMailbox({
    required this.sink,
    this.maxPending = 256,
    this.finishTimeout = const Duration(seconds: 5),
  });

  final TugboatSessionCaptureSink sink;
  final int maxPending;
  final Duration finishTimeout;

  final List<TugboatCaptureEnvelope> _queue = [];
  int _dropped = 0;
  bool _finished = false;
  int? _activeEpoch;
  Future<void> _chain = Future.value();

  int get pendingCount => _queue.length;
  int get droppedCount => _dropped;

  Future<void> start(TugboatSinkSessionContext context) {
    _activeEpoch = context.sessionEpoch;
    return _enqueue(() => sink.start(context));
  }

  void accept(TugboatCaptureEnvelope envelope) {
    if (_finished) return;
    if (_activeEpoch != null && envelope.sessionEpoch != _activeEpoch) return;
    if (_queue.length >= maxPending) {
      _dropped += 1;
      lastDropReason = 'overflow';
      return;
    }
    // Deliver synchronously so capture stays authoritative; failures are swallowed.
    _safeAccept(envelope);
  }

  String? lastDropReason;

  Future<void> flush() => _enqueue(() async {
    while (_queue.isNotEmpty) {
      final next = _queue.removeAt(0);
      _safeAccept(next);
    }
    await sink.flush();
  });

  Future<void> finish() => _enqueue(() async {
    if (_finished) return;
    while (_queue.isNotEmpty) {
      final next = _queue.removeAt(0);
      _safeAccept(next);
    }
    await sink.finish().timeout(finishTimeout, onTimeout: () {});
    _finished = true;
  });

  Future<void> dispose() => _enqueue(() => sink.dispose());

  void _safeAccept(TugboatCaptureEnvelope envelope) {
    try {
      sink.accept(envelope);
    } catch (_) {}
  }

  Future<void> _enqueue(Future<void> Function() action) {
    _chain = _chain.then((_) async {
      try {
        await action();
      } catch (_) {}
    });
    return _chain;
  }
}

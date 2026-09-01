import 'dart:typed_data';

import 'models.dart';
import 'sinks/capture_sink.dart'
    show
        TugboatCaptureEnvelope,
        TugboatCaptureSinkFactory,
        TugboatEnvelopeKind,
        TugboatSessionCaptureSink,
        TugboatSinkMailbox,
        TugboatSinkSessionContext;

export 'sinks/capture_sink.dart'
    show
        LegacyCaptureSinkAdapter,
        TugboatCaptureEnvelope,
        TugboatCaptureSinkFactory,
        TugboatEnvelopeKind,
        TugboatSessionCaptureSink,
        TugboatSinkMailbox,
        TugboatSinkSessionContext;

/// Best-effort destination for live capture output.
///
/// Sinks must never throw or block the host app. Failures are swallowed.
/// Prefer [TugboatCaptureSinkFactory] for new integrations.
abstract class TugboatCaptureSink {
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

/// Broadcasts capture output to every enabled sink via bounded mailboxes.
class TugboatCaptureSinkHub implements TugboatCaptureSink {
  TugboatCaptureSinkHub(List<TugboatCaptureSink> sinks)
    : _sinks = List<TugboatCaptureSink>.unmodifiable(sinks),
      _mailboxes = [
        for (final sink in sinks) TugboatSinkMailbox(sink: _LegacyBridge(sink)),
      ];

  final List<TugboatCaptureSink> _sinks;
  final List<TugboatSinkMailbox> _mailboxes;
  TugboatSinkSessionContext? _context;
  int _acceptCount = 0;

  int get acceptCount => _acceptCount;
  int get dropCount =>
      _mailboxes.fold<int>(0, (sum, box) => sum + box.droppedCount);
  int get pendingCount =>
      _mailboxes.fold<int>(0, (sum, box) => sum + box.pendingCount);

  Future<void> startContext(TugboatSinkSessionContext context) async {
    _context = context;
    for (final box in _mailboxes) {
      await box.start(context);
    }
  }

  @override
  void startSession(TugboatSession session) {
    final context = TugboatSinkSessionContext(
      captureSessionId: session.id,
      sessionEpoch: _context?.sessionEpoch ?? 0,
      activationRequestId: session.activationRequestId,
      explorationRunId: session.explorationRunId,
    );
    _context = context;
    for (final sink in _sinks) {
      _safe(() => sink.startSession(session));
    }
    for (final box in _mailboxes) {
      // ignore: discarded_futures
      box.start(context);
    }
  }

  @override
  void recordEvent(TugboatEvent event) {
    final context = _context;
    if (context == null) return;
    _acceptCount += 1;
    final envelope = TugboatCaptureEnvelope(
      kind: TugboatEnvelopeKind.event,
      captureSessionId: context.captureSessionId,
      sessionEpoch: context.sessionEpoch,
      activationRequestId: context.activationRequestId,
      idempotencyKey: 'event:${event.id}',
      event: event,
      createdAt: DateTime.now().toUtc(),
    );
    for (final box in _mailboxes) {
      box.accept(envelope);
    }
  }

  @override
  void recordFrame(
    TugboatFrame frame,
    Uint8List bytes, {
    required String sessionId,
    String? actionId,
  }) {
    final context = _context;
    if (context == null) return;
    if (sessionId != context.captureSessionId) return;
    _acceptCount += 1;
    final envelope = TugboatCaptureEnvelope(
      kind: TugboatEnvelopeKind.frame,
      captureSessionId: context.captureSessionId,
      sessionEpoch: context.sessionEpoch,
      activationRequestId: context.activationRequestId,
      idempotencyKey: 'frame:${frame.id}',
      frame: frame,
      frameBytes: bytes,
      actionId: actionId,
      createdAt: DateTime.now().toUtc(),
    );
    for (final box in _mailboxes) {
      box.accept(envelope);
    }
  }

  @override
  Future<void> flush() async {
    for (final box in _mailboxes) {
      await box.flush();
    }
  }

  @override
  Future<void> endSession() async {
    for (final box in _mailboxes) {
      await box.finish();
    }
  }

  @override
  void dispose() {
    for (final box in _mailboxes) {
      // ignore: discarded_futures
      box.dispose();
    }
  }

  void _safe(void Function() action) {
    try {
      action();
    } catch (_) {}
  }
}

class _LegacyBridge implements TugboatSessionCaptureSink {
  _LegacyBridge(this._legacy);

  final TugboatCaptureSink _legacy;
  bool _finished = false;

  @override
  Future<void> start(TugboatSinkSessionContext context) async {
    // Session start is invoked directly by the hub for legacy sinks.
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

/// Wraps a legacy [TugboatCaptureSink] constructor as a session factory.
class LegacySinkFactory implements TugboatCaptureSinkFactory {
  LegacySinkFactory(this._create);

  final TugboatCaptureSink Function(TugboatSinkSessionContext context) _create;

  @override
  TugboatSessionCaptureSink create(TugboatSinkSessionContext context) {
    return _LegacyBridge(_create(context));
  }
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/capture_sink.dart';
import 'package:tugboat/src/models.dart';

class _RecordingSessionSink implements TugboatSessionCaptureSink {
  final List<TugboatSinkSessionContext> starts = [];
  final List<TugboatCaptureEnvelope> accepted = [];
  int finishCount = 0;
  bool finished = false;

  @override
  Future<void> start(TugboatSinkSessionContext context) async {
    starts.add(context);
  }

  @override
  void accept(TugboatCaptureEnvelope envelope) {
    if (finished) {
      throw StateError('accept after finish');
    }
    accepted.add(envelope);
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> finish() async {
    finished = true;
    finishCount += 1;
  }

  @override
  Future<void> dispose() async {}
}

class _Factory implements TugboatCaptureSinkFactory {
  final List<_RecordingSessionSink> created = [];

  @override
  TugboatSessionCaptureSink create(TugboatSinkSessionContext context) {
    final sink = _RecordingSessionSink();
    created.add(sink);
    return sink;
  }
}

void main() {
  test('factory creates distinct sinks per session', () async {
    final factory = _Factory();
    final firstCtx = const TugboatSinkSessionContext(
      captureSessionId: 'cap-1',
      sessionEpoch: 1,
      activationRequestId: 'req-1',
    );
    final secondCtx = const TugboatSinkSessionContext(
      captureSessionId: 'cap-2',
      sessionEpoch: 2,
      activationRequestId: 'req-2',
    );

    final a = factory.create(firstCtx);
    final b = factory.create(secondCtx);
    expect(identical(a, b), isFalse);
    expect(factory.created, hasLength(2));

    await a.start(firstCtx);
    await b.start(secondCtx);
    expect(factory.created[0].starts.single.captureSessionId, 'cap-1');
    expect(factory.created[1].starts.single.captureSessionId, 'cap-2');
  });

  test('mailbox rejects accept after finish', () async {
    final sink = _RecordingSessionSink();
    final box = TugboatSinkMailbox(sink: sink);
    const ctx = TugboatSinkSessionContext(
      captureSessionId: 'cap-1',
      sessionEpoch: 1,
    );
    await box.start(ctx);
    box.accept(
      TugboatCaptureEnvelope(
        kind: TugboatEnvelopeKind.event,
        captureSessionId: 'cap-1',
        sessionEpoch: 1,
        idempotencyKey: 'e1',
        event: const TugboatEvent(
          id: 'e1',
          atMs: 0,
          type: 'capture_diagnostic',
        ),
      ),
    );
    await box.finish();
    box.accept(
      TugboatCaptureEnvelope(
        kind: TugboatEnvelopeKind.event,
        captureSessionId: 'cap-1',
        sessionEpoch: 1,
        idempotencyKey: 'e2',
        event: const TugboatEvent(
          id: 'e2',
          atMs: 1,
          type: 'capture_diagnostic',
        ),
      ),
    );
    expect(sink.accepted, hasLength(1));
    expect(sink.finishCount, 1);
  });

  test('legacy hub still isolates sink failures', () async {
    final good = _RecordingLegacySink();
    final bad = _ThrowingLegacySink();
    final hub = TugboatCaptureSinkHub([bad, good]);
    final session = TugboatSession(
      id: 'session-1',
      startedAt: DateTime.utc(2026, 6, 19),
      platform: 'ios',
      viewport: const TugboatRect(0, 0, 390, 844),
    );
    hub.startSession(session);
    hub.recordEvent(
      const TugboatEvent(id: 'e1', atMs: 0, type: 'capture_diagnostic'),
    );
    await hub.flush();
    await hub.endSession();
    expect(good.events, hasLength(1));
  });
}

class _RecordingLegacySink implements TugboatCaptureSink {
  final List<TugboatEvent> events = [];

  @override
  void startSession(TugboatSession session) {}

  @override
  void recordEvent(TugboatEvent event) => events.add(event);

  @override
  void recordFrame(
    TugboatFrame frame,
    Uint8List bytes, {
    required String sessionId,
    String? actionId,
  }) {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> endSession() async {}

  @override
  void dispose() {}
}

class _ThrowingLegacySink implements TugboatCaptureSink {
  @override
  void startSession(TugboatSession session) {}

  @override
  void recordEvent(TugboatEvent event) => throw StateError('boom');

  @override
  void recordFrame(
    TugboatFrame frame,
    Uint8List bytes, {
    required String sessionId,
    String? actionId,
  }) {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> endSession() async {}

  @override
  void dispose() {}
}

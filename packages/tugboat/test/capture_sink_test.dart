import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/src/capture_sink.dart';
import 'package:tugboat/src/models.dart';

class _RecordingSink implements TugboatCaptureSink {
  final List<TugboatSession> sessions = [];
  final List<TugboatEvent> events = [];
  final List<String> frameIds = [];
  int flushCount = 0;
  int endSessionCount = 0;

  @override
  void startSession(TugboatSession session) => sessions.add(session);

  @override
  void recordEvent(TugboatEvent event) => events.add(event);

  @override
  void recordFrame(
    TugboatFrame frame,
    Uint8List bytes, {
    required String sessionId,
    String? actionId,
  }) {
    frameIds.add(frame.id);
  }

  @override
  Future<void> flush() async {
    flushCount++;
  }

  @override
  Future<void> endSession() async {
    endSessionCount++;
  }

  @override
  void dispose() {}
}

void main() {
  test('hub broadcasts capture output to every sink', () async {
    final first = _RecordingSink();
    final second = _RecordingSink();
    final hub = TugboatCaptureSinkHub([first, second]);
    final session = TugboatSession(
      id: 'session-1',
      startedAt: DateTime.utc(2026, 6, 19),
      platform: 'ios',
      viewport: const TugboatRect(0, 0, 390, 844),
    );
    final event = TugboatEvent(
      id: 'event-1',
      atMs: 1,
      type: 'capture_diagnostic',
    );
    final frame = const TugboatFrame(
      id: 'frame-0',
      atMs: 0,
      width: 10,
      height: 10,
      contentHash: 'hash',
    );

    hub.startSession(session);
    hub.recordEvent(event);
    hub.recordFrame(
      frame,
      Uint8List.fromList([1]),
      sessionId: session.id,
      actionId: 'A-1',
    );
    await hub.flush();
    await hub.endSession();
    hub.dispose();

    expect(first.sessions, hasLength(1));
    expect(second.sessions, hasLength(1));
    expect(first.events, hasLength(1));
    expect(second.events, hasLength(1));
    expect(first.frameIds, ['frame-0']);
    expect(second.frameIds, ['frame-0']);
    expect(first.flushCount, 1);
    expect(second.endSessionCount, 1);
  });
}

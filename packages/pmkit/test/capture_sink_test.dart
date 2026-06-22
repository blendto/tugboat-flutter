import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pmkit/src/capture_sink.dart';
import 'package:pmkit/src/models.dart';

class _RecordingSink implements PmkitCaptureSink {
  final List<PmkitSession> sessions = [];
  final List<PmkitEvent> events = [];
  final List<String> frameIds = [];
  int flushCount = 0;
  int endSessionCount = 0;

  @override
  void startSession(PmkitSession session) => sessions.add(session);

  @override
  void recordEvent(PmkitEvent event) => events.add(event);

  @override
  void recordFrame(
    PmkitFrame frame,
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
    final hub = PmkitCaptureSinkHub([first, second]);
    final session = PmkitSession(
      id: 'session-1',
      startedAt: DateTime.utc(2026, 6, 19),
      platform: 'ios',
      viewport: const PmkitRect(0, 0, 390, 844),
    );
    final event = PmkitEvent(id: 'event-1', atMs: 1, type: 'tap');
    final frame = const PmkitFrame(
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

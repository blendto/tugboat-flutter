import 'dart:async';
import 'dart:typed_data';

import 'capture_sink.dart';
import 'exploration_transport.dart';
import 'models.dart';

/// WebSocket sink used by local CLI exploration runs.
class ExplorationCaptureSink implements PmkitCaptureSink {
  ExplorationCaptureSink({
    required String url,
    required String? runId,
    required PmkitExplorationControlHandler onControl,
  }) : transport = PmkitExplorationTransport(
         url: url,
         runId: runId,
         onControl: onControl,
       );

  final PmkitExplorationTransport transport;

  @override
  void startSession(PmkitSession session) {
    transport.sendSession(session);
  }

  @override
  void recordEvent(PmkitEvent event) {
    transport.sendEvent(event);
  }

  @override
  void recordFrame(
    PmkitFrame frame,
    Uint8List bytes, {
    required String sessionId,
    String? actionId,
  }) {
    transport.sendFrame(
      frame,
      bytes,
      sessionId: sessionId,
      actionId: actionId,
    );
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> endSession() async {}

  @override
  void dispose() {
    transport.dispose();
  }

  Future<void> connect() => transport.connect();
}

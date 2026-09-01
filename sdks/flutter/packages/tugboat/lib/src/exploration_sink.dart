import 'dart:async';
import 'dart:typed_data';

import 'capture_sink.dart';
import 'exploration_transport.dart';
import 'models.dart';

/// WebSocket sink used by local CLI exploration runs.
class ExplorationCaptureSink implements TugboatCaptureSink {
  ExplorationCaptureSink({
    required String url,
    required String? runId,
    required TugboatExplorationControlHandler onControl,
    TugboatExplorationConnectionHandler? onConnected,
    TugboatExplorationConnectionHandler? onDisconnected,
  }) : transport = TugboatExplorationTransport(
         url: url,
         runId: runId,
         onControl: onControl,
         onConnected: onConnected,
         onDisconnected: onDisconnected,
       );

  final TugboatExplorationTransport transport;

  @override
  void startSession(TugboatSession session) {
    transport.sendSession(session);
  }

  @override
  void recordEvent(TugboatEvent event) {
    transport.sendEvent(event);
  }

  @override
  void recordFrame(
    TugboatFrame frame,
    Uint8List bytes, {
    required String sessionId,
    String? actionId,
  }) {
    transport.sendFrame(frame, bytes, sessionId: sessionId, actionId: actionId);
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

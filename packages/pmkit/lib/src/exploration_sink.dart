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
    PmkitExplorationConnectionHandler? onConnected,
    PmkitExplorationConnectionHandler? onDisconnected,
  }) : transport = PmkitExplorationTransport(
         url: url,
         runId: runId,
         onControl: onControl,
         onConnected: onConnected,
         onDisconnected: onDisconnected,
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
    // CLI exploration runs use ADB screenshots; skip frame bytes on the wire.
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

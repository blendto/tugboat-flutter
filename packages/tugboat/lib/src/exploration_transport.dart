import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'anchors.dart';
import 'models.dart';

typedef TugboatExplorationControlHandler =
    void Function(Map<String, dynamic> message);

/// Best-effort live transport used only by SDK-enabled exploration builds.
///
/// Capture remains authoritative in the in-memory session. Connection and
/// transport failures are intentionally swallowed so the host app is never
/// blocked by a missing local collector.
class TugboatExplorationTransport {
  TugboatExplorationTransport({
    required this.url,
    required this.runId,
    required this.onControl,
  });

  final String url;
  final String? runId;
  final TugboatExplorationControlHandler onControl;

  WebSocket? _socket;
  bool _disposed = false;
  bool _connecting = false;
  final List<Object> _pending = [];

  Future<void> connect() async {
    if (_disposed || _connecting || _socket != null) return;
    _connecting = true;
    try {
      final socket = await WebSocket.connect(url);
      if (_disposed) {
        await socket.close();
        return;
      }
      _socket = socket;
      socket.listen(
        _onMessage,
        onDone: _onDisconnected,
        onError: (_) => _onDisconnected(),
        cancelOnError: true,
      );
      _flush();
    } catch (_) {
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  void sendSession(TugboatSession session) {
    _sendJson({
      'type': 'session',
      if (runId != null) 'explorationRunId': runId,
      'fingerprintSchemaVersion': tugboatFingerprintSchemaVersion,
      'platform': session.platform,
      'payload': session.toJson()['session'],
    });
  }

  void sendEvent(TugboatEvent event) {
    _sendJson({
      'type': 'event',
      if (event.sessionId != null) 'sessionId': event.sessionId,
      if (event.explorationRunId != null)
        'explorationRunId': event.explorationRunId,
      if (event.actionId != null) 'actionId': event.actionId,
      'payload': event.toJson(),
    });
  }

  void sendFrame(
    TugboatFrame frame,
    Uint8List bytes, {
    required String sessionId,
    String? actionId,
  }) {
    _sendJson({
      'type': 'frame',
      'sessionId': sessionId,
      if (runId != null) 'explorationRunId': runId,
      if (actionId != null) 'actionId': actionId,
      'payload': frame.toJson(),
    });
    _send(bytes);
  }

  void acknowledge(String command, {String? actionId}) {
    _sendJson({
      'type': 'control_ack',
      'payload': {
        'command': command,
        if (actionId != null) 'actionId': actionId,
      },
    });
  }

  void dispose() {
    _disposed = true;
    _pending.clear();
    unawaited(_socket?.close());
    _socket = null;
  }

  void _sendJson(Map<String, Object?> message) => _send(jsonEncode(message));

  void _send(Object message) {
    final socket = _socket;
    if (socket != null) {
      try {
        socket.add(message);
        return;
      } catch (_) {
        _onDisconnected();
      }
    }
    if (_pending.length >= 200) _pending.removeAt(0);
    _pending.add(message);
    unawaited(connect());
  }

  void _flush() {
    final socket = _socket;
    if (socket == null) return;
    for (final message in _pending) {
      socket.add(message);
    }
    _pending.clear();
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    try {
      onControl(Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (_) {
      // Ignore malformed collector control messages.
    }
  }

  void _onDisconnected() {
    _socket = null;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    Future<void>.delayed(const Duration(seconds: 2), connect);
  }
}

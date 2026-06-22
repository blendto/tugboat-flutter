import 'dart:typed_data';

import 'models.dart';

/// Best-effort destination for live capture output.
///
/// Sinks must never throw or block the host app. Failures are swallowed.
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

/// Broadcasts capture output to every enabled sink.
class TugboatCaptureSinkHub implements TugboatCaptureSink {
  TugboatCaptureSinkHub(this._sinks);

  final List<TugboatCaptureSink> _sinks;

  @override
  void startSession(TugboatSession session) {
    for (final sink in _sinks) {
      _safe(() => sink.startSession(session));
    }
  }

  @override
  void recordEvent(TugboatEvent event) {
    for (final sink in _sinks) {
      _safe(() => sink.recordEvent(event));
    }
  }

  @override
  void recordFrame(
    TugboatFrame frame,
    Uint8List bytes, {
    required String sessionId,
    String? actionId,
  }) {
    for (final sink in _sinks) {
      _safe(
        () => sink.recordFrame(
          frame,
          bytes,
          sessionId: sessionId,
          actionId: actionId,
        ),
      );
    }
  }

  @override
  Future<void> flush() async {
    for (final sink in _sinks) {
      await _safeAsync(sink.flush);
    }
  }

  @override
  Future<void> endSession() async {
    for (final sink in _sinks) {
      await _safeAsync(sink.endSession);
    }
  }

  @override
  void dispose() {
    for (final sink in _sinks) {
      _safe(sink.dispose);
    }
  }

  void _safe(void Function() action) {
    try {
      action();
    } catch (_) {
      // Capture must remain authoritative even when sinks fail.
    }
  }

  Future<void> _safeAsync(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // Capture must remain authoritative even when sinks fail.
    }
  }
}

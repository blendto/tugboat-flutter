import 'dart:async';

import 'capture_sink.dart';
import 'health.dart';

/// Sink counters for the whole process, across capture activations.
///
/// Each activation builds its own [TugboatCaptureSinkHub], and deactivating
/// disposes it. The disposed hub's collector sink can still be draining: it
/// counts the backlog it discards when disposed, and a request it already
/// sent stays pending until it finishes. Health that read only the current
/// hub would reset to zero at every activation and hide that loss, so a
/// retired hub keeps contributing until it is disposed and holds nothing,
/// then its final counts fold into the settled totals.
class TugboatSinkLedger {
  TugboatSinkLedger._();

  static final TugboatSinkLedger instance = TugboatSinkLedger._();

  int _settledAccepted = 0;
  int _settledDropped = 0;
  final List<_RetiredHub> _retired = [];

  /// Keeps counting [hub] after its controller lets go of it. [disposed]
  /// completes once `hub.dispose()` has been called.
  void retire(TugboatCaptureSinkHub hub, Future<void> disposed) {
    final entry = _RetiredHub(hub);
    _retired.add(entry);
    unawaited(
      disposed
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() => entry.disposed = true),
    );
  }

  /// Totals over every hub this process has used, [current] included.
  /// `pending` is what is still held now; `accepted` and `dropped` are
  /// running totals.
  TugboatSinkHealth snapshot(TugboatCaptureSinkHub? current) {
    _settle();
    var pending = current?.pendingCount ?? 0;
    var accepted = _settledAccepted + (current?.acceptCount ?? 0);
    var dropped = _settledDropped + (current?.dropCount ?? 0);
    for (final entry in _retired) {
      pending += entry.hub.pendingCount;
      accepted += entry.hub.acceptCount;
      dropped += entry.hub.dropCount;
    }
    return TugboatSinkHealth(
      pending: pending,
      accepted: accepted,
      dropped: dropped,
    );
  }

  void _settle() {
    _retired.removeWhere((entry) {
      if (!entry.disposed || entry.hub.pendingCount > 0) return false;
      _settledAccepted += entry.hub.acceptCount;
      _settledDropped += entry.hub.dropCount;
      return true;
    });
  }

  /// Clears every total between tests.
  void resetForTest() {
    _settledAccepted = 0;
    _settledDropped = 0;
    _retired.clear();
  }
}

class _RetiredHub {
  _RetiredHub(this.hub);

  final TugboatCaptureSinkHub hub;
  bool disposed = false;
}

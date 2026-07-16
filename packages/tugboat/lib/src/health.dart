/// Bounded, sanitized SDK health snapshot for integrators.
class TugboatSdkHealth {
  const TugboatSdkHealth({
    required this.lifecycle,
    required this.profile,
    this.activationRequestId,
    this.captureSessionId,
    this.sinks = const TugboatSinkHealth(),
    this.outbox,
    this.screenshots = const TugboatScreenshotBudgetHealth(),
    this.truncated = false,
    this.recentFailures = const [],
  });

  final String lifecycle;
  final String profile;
  final String? activationRequestId;
  final String? captureSessionId;
  final TugboatSinkHealth sinks;
  final TugboatOutboxHealth? outbox;
  final TugboatScreenshotBudgetHealth screenshots;
  final bool truncated;
  final List<TugboatSanitizedFailure> recentFailures;

  Map<String, Object?> toJson() => {
    'lifecycle': lifecycle,
    'profile': profile,
    if (activationRequestId != null) 'activationRequestId': activationRequestId,
    if (captureSessionId != null) 'captureSessionId': captureSessionId,
    'sinks': sinks.toJson(),
    if (outbox != null) 'outbox': outbox!.toJson(),
    'screenshots': screenshots.toJson(),
    'truncated': truncated,
    'recentFailures': recentFailures.map((f) => f.toJson()).toList(),
  };
}

class TugboatSinkHealth {
  const TugboatSinkHealth({
    this.pending = 0,
    this.accepted = 0,
    this.dropped = 0,
  });

  final int pending;
  final int accepted;
  final int dropped;

  Map<String, Object?> toJson() => {
    'pending': pending,
    'accepted': accepted,
    'dropped': dropped,
  };
}

class TugboatOutboxHealth {
  const TugboatOutboxHealth({
    this.enabled = false,
    this.pending = 0,
    this.bytes = 0,
    this.quarantined = 0,
  });

  final bool enabled;
  final int pending;
  final int bytes;
  final int quarantined;

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'pending': pending,
    'bytes': bytes,
    'quarantined': quarantined,
  };
}

class TugboatScreenshotBudgetHealth {
  const TugboatScreenshotBudgetHealth({
    this.degraded = false,
    this.dropped = 0,
    this.coalesced = 0,
    this.lastDropReason,
    this.avgQueueWaitMicros = 0,
    this.avgEncodeMicros = 0,
    this.avgReadbackMicros = 0,
  });

  final bool degraded;
  final int dropped;
  final int coalesced;
  final String? lastDropReason;
  final int avgQueueWaitMicros;
  final int avgEncodeMicros;
  final int avgReadbackMicros;

  Map<String, Object?> toJson() => {
    'degraded': degraded,
    'dropped': dropped,
    'coalesced': coalesced,
    if (lastDropReason != null) 'lastDropReason': lastDropReason,
    'avgQueueWaitMicros': avgQueueWaitMicros,
    'avgEncodeMicros': avgEncodeMicros,
    'avgReadbackMicros': avgReadbackMicros,
  };
}

class TugboatSanitizedFailure {
  const TugboatSanitizedFailure({
    required this.at,
    required this.code,
    this.component,
  });

  final DateTime at;
  final String code;
  final String? component;

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'code': code,
    if (component != null) 'component': component,
  };
}

/// Rolling screenshot budget / stage counters (no pixels or labels).
class TugboatScreenshotBudgetTracker {
  TugboatScreenshotBudgetTracker({
    this.window = const Duration(seconds: 5),
    this.budgetMicros = 80 * 1000, // 80ms per window default
  });

  Duration window;
  int budgetMicros;

  final List<_Sample> _samples = [];
  int dropped = 0;
  int coalesced = 0;
  String? lastDropReason;
  bool degraded = false;

  int _sumQueue = 0;
  int _sumEncode = 0;
  int _sumReadback = 0;
  int _count = 0;

  void record({
    required int queueWaitMicros,
    required int readbackMicros,
    required int encodeMicros,
    required int encodedBytes,
    String? dropReason,
    bool coalescedCapture = false,
  }) {
    final now = DateTime.now();
    _prune(now);
    final cost = queueWaitMicros + readbackMicros + encodeMicros;
    _samples.add(_Sample(now, cost));
    _sumQueue += queueWaitMicros;
    _sumEncode += encodeMicros;
    _sumReadback += readbackMicros;
    _count += 1;
    if (coalescedCapture) coalesced += 1;
    if (dropReason != null) {
      dropped += 1;
      lastDropReason = dropReason;
    }
    degraded = _samples.fold<int>(0, (s, e) => s + e.cost) > budgetMicros;
  }

  bool get shouldSkipEligible => degraded;

  TugboatScreenshotBudgetHealth snapshot() {
    final n = _count == 0 ? 1 : _count;
    return TugboatScreenshotBudgetHealth(
      degraded: degraded,
      dropped: dropped,
      coalesced: coalesced,
      lastDropReason: lastDropReason,
      avgQueueWaitMicros: _sumQueue ~/ n,
      avgEncodeMicros: _sumEncode ~/ n,
      avgReadbackMicros: _sumReadback ~/ n,
    );
  }

  void _prune(DateTime now) {
    _samples.removeWhere((s) => now.difference(s.at) > window);
    degraded = _samples.fold<int>(0, (s, e) => s + e.cost) > budgetMicros;
  }
}

class _Sample {
  _Sample(this.at, this.cost);
  final DateTime at;
  final int cost;
}

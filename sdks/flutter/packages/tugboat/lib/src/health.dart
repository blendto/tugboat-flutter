/// Bounded, sanitized SDK health snapshot for integrators.
class TugboatSdkHealth {
  const TugboatSdkHealth({
    required this.lifecycle,
    this.activationRequestId,
    this.captureSessionId,
    this.sinks = const TugboatSinkHealth(),
    this.screenshots = const TugboatScreenshotBudgetHealth(),
    this.captureDiagnostics = const TugboatCaptureDiagnosticHealth(),
    this.evidence = const TugboatEvidenceHealth(),
    this.truncated = false,
    this.recentFailures = const [],
  });

  final String lifecycle;
  final String? activationRequestId;
  final String? captureSessionId;
  final TugboatSinkHealth sinks;
  final TugboatScreenshotBudgetHealth screenshots;

  /// Bounded, privacy-safe capture outcome counts. Additive to screenshot
  /// budget health so existing consumers remain compatible.
  final TugboatCaptureDiagnosticHealth captureDiagnostics;

  /// Bounded counters for external app-event and network evidence.
  final TugboatEvidenceHealth evidence;
  final bool truncated;
  final List<TugboatSanitizedFailure> recentFailures;

  Map<String, Object?> toJson() => {
    'lifecycle': lifecycle,
    if (activationRequestId != null) 'activationRequestId': activationRequestId,
    if (captureSessionId != null) 'captureSessionId': captureSessionId,
    'sinks': sinks.toJson(),
    'screenshots': screenshots.toJson(),
    'captureDiagnostics': captureDiagnostics.toJson(),
    'evidence': evidence.toJson(),
    'truncated': truncated,
    'recentFailures': recentFailures.map((f) => f.toJson()).toList(),
  };
}

/// Bounded counters for opt-in external and network evidence. Drop reasons use
/// a closed vocabulary and never retain rejected raw values or paths.
class TugboatEvidenceHealth {
  const TugboatEvidenceHealth({
    this.externalAccepted = 0,
    this.externalDropped = 0,
    this.networkAccepted = 0,
    this.networkDropped = 0,
    this.networkDuplicateFinishes = 0,
    this.lastDropReason,
  });

  final int externalAccepted;
  final int externalDropped;
  final int networkAccepted;
  final int networkDropped;
  final int networkDuplicateFinishes;
  final String? lastDropReason;

  Map<String, Object?> toJson() => {
    'externalAccepted': externalAccepted,
    'externalDropped': externalDropped,
    'networkAccepted': networkAccepted,
    'networkDropped': networkDropped,
    'networkDuplicateFinishes': networkDuplicateFinishes,
    if (lastDropReason != null) 'lastDropReason': lastDropReason,
  };
}

/// Rolling capture-resolution evidence. Outcome names are a closed,
/// non-sensitive taxonomy; no errors, pixels, labels, or stack traces appear
/// here.
class TugboatCaptureDiagnosticHealth {
  const TugboatCaptureDiagnosticHealth({
    this.total = 0,
    this.lastOutcome,
    this.outcomes = const {},
  });

  final int total;
  final String? lastOutcome;
  final Map<String, int> outcomes;

  Map<String, Object?> toJson() => {
    'total': total,
    if (lastOutcome != null) 'lastOutcome': lastOutcome,
    'outcomes': Map<String, int>.unmodifiable(outcomes),
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

class TugboatScreenshotBudgetHealth {
  const TugboatScreenshotBudgetHealth({
    this.degraded = false,
    this.dropped = 0,
    this.coalesced = 0,
    this.lastDropReason,
    this.avgQueueWaitMicros = 0,
    this.avgFrameWaitMicros = 0,
    this.avgEncodeMicros = 0,
    this.avgReadbackMicros = 0,
    this.avgMaskMicros = 0,
  });

  final bool degraded;
  final int dropped;
  final int coalesced;
  final String? lastDropReason;
  final int avgQueueWaitMicros;
  final int avgFrameWaitMicros;
  final int avgEncodeMicros;
  final int avgReadbackMicros;
  final int avgMaskMicros;

  Map<String, Object?> toJson() => {
    'degraded': degraded,
    'dropped': dropped,
    'coalesced': coalesced,
    if (lastDropReason != null) 'lastDropReason': lastDropReason,
    'avgQueueWaitMicros': avgQueueWaitMicros,
    'avgFrameWaitMicros': avgFrameWaitMicros,
    'avgEncodeMicros': avgEncodeMicros,
    'avgReadbackMicros': avgReadbackMicros,
    'avgMaskMicros': avgMaskMicros,
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
    this.budgetMicros = 60 * 1000, // 60ms per window default
  });

  Duration window;
  int budgetMicros;

  final List<_Sample> _samples = [];
  int dropped = 0;
  int coalesced = 0;
  String? lastDropReason;
  bool degraded = false;

  int _sumQueue = 0;
  int _sumFrameWait = 0;
  int _sumEncode = 0;
  int _sumReadback = 0;
  int _sumMask = 0;
  int _count = 0;

  void record({
    required int queueWaitMicros,
    int frameWaitMicros = 0,
    required int readbackMicros,
    int maskMicros = 0,
    required int encodeMicros,
    required int encodedBytes,
    String? dropReason,
    bool coalescedCapture = false,
  }) {
    final now = DateTime.now();
    _prune(now);
    final cost =
        queueWaitMicros +
        frameWaitMicros +
        readbackMicros +
        maskMicros +
        encodeMicros;
    _samples.add(_Sample(now, cost));
    _sumQueue += queueWaitMicros;
    _sumFrameWait += frameWaitMicros;
    _sumEncode += encodeMicros;
    _sumReadback += readbackMicros;
    _sumMask += maskMicros;
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
      avgFrameWaitMicros: _sumFrameWait ~/ n,
      avgEncodeMicros: _sumEncode ~/ n,
      avgReadbackMicros: _sumReadback ~/ n,
      avgMaskMicros: _sumMask ~/ n,
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

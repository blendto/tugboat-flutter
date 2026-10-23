import 'dart:async';

import 'collector_retry_after.dart';

/// Per-lane `Retry-After` waits for [CollectorHttpSink].
enum CollectorDeliveryLane { lifecycle, events, frames }

/// Returns a cancel function for the scheduled callback.
typedef CollectorLaneTimerSchedule =
    void Function() Function(Duration wait, void Function() onFire);

/// The largest `Retry-After` cap honoured: the engine's collector duration
/// range (`config.cpp`, 0 to 86 400 000 ms).
const collectorRetryAfterCapLimit = Duration(hours: 24);

/// [cap] in milliseconds, clamped to zero through
/// [collectorRetryAfterCapLimit]. Zero honours no hint.
int clampCollectorRetryAfterCapMs(Duration cap) {
  if (cap <= Duration.zero) return 0;
  if (cap >= collectorRetryAfterCapLimit) {
    return collectorRetryAfterCapLimit.inMilliseconds;
  }
  return cap.inMilliseconds;
}

class CollectorLaneDelays {
  /// [elapsed] is a monotonic clock (a [Stopwatch] unless a test injects
  /// one), so a wall-clock change never ends a wait early.
  CollectorLaneDelays(
    this._onLaneReady, {
    Duration Function()? elapsed,
    CollectorLaneTimerSchedule? scheduleTimer,
  }) : _elapsed = elapsed ?? _stopwatchClock(),
       _scheduleTimer = scheduleTimer ?? _defaultScheduleTimer;

  final Duration Function() _elapsed;
  final void Function(CollectorDeliveryLane lane) _onLaneReady;
  final CollectorLaneTimerSchedule _scheduleTimer;
  final Map<CollectorDeliveryLane, Duration> _notBefore = {};
  final Map<CollectorDeliveryLane, void Function()> _cancelTimer = {};

  static Duration Function() _stopwatchClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  static void Function() _defaultScheduleTimer(
    Duration wait,
    void Function() onFire,
  ) {
    final timer = Timer(wait, onFire);
    return timer.cancel;
  }

  void clear() {
    for (final cancel in _cancelTimer.values) {
      cancel();
    }
    _cancelTimer.clear();
    _notBefore.clear();
  }

  bool isBlocked(CollectorDeliveryLane lane) {
    final until = _notBefore[lane];
    if (until == null) return false;
    if (_elapsed() >= until) {
      _clearLane(lane);
      return false;
    }
    return true;
  }

  /// Shortens a lifecycle wait to at most [capMs] from now (session ending).
  void clampLifecycleEnding(int capMs) {
    const lane = CollectorDeliveryLane.lifecycle;
    final until = _notBefore[lane];
    if (until == null) return;
    final maxUntil = _elapsed() + Duration(milliseconds: capMs);
    if (until > maxUntil) _arm(lane, maxUntil);
  }

  /// Arms [lane] from an HTTP 429 or 503 `Retry-After` header, replacing any
  /// earlier wait. An HTTP-date is read against [wallNow].
  void armFromResponse(
    CollectorDeliveryLane lane,
    int statusCode,
    Map<String, String> headers,
    DateTime wallNow, {
    required int capMs,
  }) {
    if (statusCode != 429 && statusCode != 503) return;
    final delayMs = parseCollectorRetryAfterDelayMs(
      headers['retry-after'],
      wallNow,
      capMs: capMs,
    );
    if (delayMs == null || delayMs <= 0) return;
    _arm(lane, _elapsed() + Duration(milliseconds: delayMs));
  }

  /// Sets [lane]'s not-before and its timer; a wait already over readies the
  /// lane now.
  void _arm(CollectorDeliveryLane lane, Duration until) {
    _clearLane(lane);
    final wait = until - _elapsed();
    if (wait <= Duration.zero) {
      _onLaneReady(lane);
      return;
    }
    _notBefore[lane] = until;
    _cancelTimer[lane] = _scheduleTimer(wait, () {
      _clearLane(lane);
      _onLaneReady(lane);
    });
  }

  void _clearLane(CollectorDeliveryLane lane) {
    _cancelTimer.remove(lane)?.call();
    _notBefore.remove(lane);
  }
}

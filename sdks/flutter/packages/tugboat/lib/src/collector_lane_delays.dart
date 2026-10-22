import 'dart:async';

import 'package:flutter/foundation.dart';

import 'collector_retry_after.dart';

/// Per-lane `Retry-After` waits for [CollectorHttpSink].
enum CollectorDeliveryLane { lifecycle, events, frames }

/// Returns a cancel function for the scheduled callback.
typedef CollectorLaneTimerSchedule = void Function() Function(
  Duration wait,
  void Function() onFire,
);

class CollectorLaneDelays {
  CollectorLaneDelays(
    this._now,
    this._onLaneReady, {
    @visibleForTesting CollectorLaneTimerSchedule? scheduleTimer,
  }) : _scheduleTimer = scheduleTimer ?? _defaultScheduleTimer;

  final DateTime Function() _now;
  final void Function() _onLaneReady;
  final CollectorLaneTimerSchedule _scheduleTimer;
  final Map<CollectorDeliveryLane, DateTime> _notBefore = {};
  final Map<CollectorDeliveryLane, void Function()> _cancelTimer = {};

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
    if (!_now().isBefore(until)) {
      _clearLane(lane);
      return false;
    }
    return true;
  }

  void armFromResponse(
    CollectorDeliveryLane lane,
    int statusCode,
    Map<String, String> headers, {
    int capMs = collectorMaxRetryAfterMs,
  }) {
    if (statusCode != 429 && statusCode != 503) return;
    final raw = headers['retry-after'];
    if (raw == null) return;
    final delayMs = parseCollectorRetryAfterDelayMs(raw, _now(), capMs: capMs);
    if (delayMs == null || delayMs <= 0) return;
    final until = _now().add(Duration(milliseconds: delayMs));
    _notBefore[lane] = until;
    _cancelTimer[lane]?.call();
    final wait = until.difference(_now());
    if (wait <= Duration.zero) {
      _clearLane(lane);
      _onLaneReady();
      return;
    }
    _cancelTimer[lane] = _scheduleTimer(wait, () {
      _clearLane(lane);
      _onLaneReady();
    });
  }

  void _clearLane(CollectorDeliveryLane lane) {
    _cancelTimer.remove(lane)?.call();
    _notBefore.remove(lane);
  }
}

import 'collector_retry_after.dart';

/// Per-lane `Retry-After` waits for [CollectorHttpSink].
enum CollectorDeliveryLane { lifecycle, events, frames }

class CollectorLaneDelays {
  CollectorLaneDelays(this._now);

  final DateTime Function() _now;
  final Map<CollectorDeliveryLane, DateTime> _notBefore = {};

  void clear() => _notBefore.clear();

  Future<void> waitFor(CollectorDeliveryLane lane) async {
    final until = _notBefore[lane];
    if (until == null) return;
    final now = _now();
    if (!now.isBefore(until)) {
      _notBefore.remove(lane);
      return;
    }
    await Future<void>.delayed(until.difference(now));
    _notBefore.remove(lane);
  }

  void armFromResponse(
    CollectorDeliveryLane lane,
    int statusCode,
    Map<String, String> headers,
  ) {
    if (statusCode != 429 && statusCode != 503) return;
    final raw = headers['retry-after'];
    if (raw == null) return;
    final delayMs = parseCollectorRetryAfterDelayMs(raw, _now());
    if (delayMs == null || delayMs <= 0) return;
    _notBefore[lane] = _now().add(Duration(milliseconds: delayMs));
  }
}

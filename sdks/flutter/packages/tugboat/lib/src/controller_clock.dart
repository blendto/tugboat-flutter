/// The clocks a capture controller reads: the wall clock for the session id
/// and `startedAt`, and the elapsed clock for event `atMs`.
///
/// Production uses [TugboatStopwatchClock]. Tests inject a fake through the
/// controller's `debugClock` to run the session engine's conformance
/// scenarios deterministically. Not exported.
abstract interface class TugboatControllerClock {
  /// The current wall-clock time.
  DateTime now();

  /// Milliseconds since the last [restart].
  int get elapsedMilliseconds;

  /// Restarts the elapsed clock from zero; called at session start.
  void restart();
}

/// [DateTime.now] and a [Stopwatch]: the controller's shipped behaviour.
class TugboatStopwatchClock implements TugboatControllerClock {
  final Stopwatch _stopwatch = Stopwatch();

  @override
  DateTime now() => DateTime.now();

  @override
  int get elapsedMilliseconds => _stopwatch.elapsedMilliseconds;

  @override
  void restart() {
    _stopwatch
      ..reset()
      ..start();
  }
}

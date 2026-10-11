/// The elapsed clock a capture controller reads for event `atMs`.
///
/// Production uses [TugboatStopwatchClock]. Tests pass a fake as the
/// controller's `debugClock` to run the session engine's conformance
/// scenarios deterministically. Not exported.
abstract interface class TugboatElapsedClock {
  /// Milliseconds since the last [restart].
  int get elapsedMilliseconds;

  /// Restarts the clock from zero; called at session start.
  void restart();
}

/// A [Stopwatch]: the controller's shipped behaviour.
class TugboatStopwatchClock implements TugboatElapsedClock {
  final Stopwatch _stopwatch = Stopwatch();

  @override
  int get elapsedMilliseconds => _stopwatch.elapsedMilliseconds;

  @override
  void restart() {
    _stopwatch
      ..reset()
      ..start();
  }
}

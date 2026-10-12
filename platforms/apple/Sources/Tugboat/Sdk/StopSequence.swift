import Foundation

/// `stop()` in the order the engine needs: `session.end`, then, once the
/// `session_end` post settled or after `maxDrain`, the finish step, which
/// submits `engine.dispose` and destroys the handle. `engine.dispose` is
/// rejected while a session is live and starts no new IO, so disposing
/// before the drain would lose `session_end` (C5).
///
/// Nothing blocks: the bounded wait is a deadline on the `tugboat.stop`
/// queue, and `finish` runs exactly once on that queue, whichever comes
/// first. The caller's thread (main) only posts `session.end`. A session
/// that already ended posts no `session_end`, so it waits out `maxDrain`.
final class StopSequence {
  /// The engine's `endDrainTimeoutMs` (5 s) plus one `jsonTimeoutMs`
  /// (15 s) for the `session_end` post itself, plus slack for its answer:
  /// past this nothing more will be delivered.
  static let defaultMaxDrain: TimeInterval = 25

  private let maxDrain: TimeInterval
  private let queue: DispatchQueue

  init(maxDrain: TimeInterval = StopSequence.defaultMaxDrain, queue: DispatchQueue = DispatchQueue(label: "tugboat.stop", qos: .utility)) {
    self.maxDrain = maxDrain
    self.queue = queue
  }

  func run(watcher: SessionEndWatcher, endSession: () -> Void, finish: @escaping () -> Void) {
    let finished = Locked(false)
    let finishOnce = {
      let first = finished.withLock { (done: inout Bool) -> Bool in
        defer { done = true }
        return !done
      }
      if first { finish() }
    }
    watcher.whenSettled { [queue] in queue.async { finishOnce() } }
    endSession()
    queue.asyncAfter(deadline: .now() + maxDrain) { finishOnce() }
  }
}

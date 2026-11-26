import Foundation

/// `stop()` in the order the engine needs: `session.end`, then, once the
/// `session_end` post settled or after `maxDrain`, the finish step, which
/// submits `engine.dispose` and destroys the handle. `engine.dispose` is
/// rejected while a session is live and starts no new IO, so disposing
/// before the drain would lose `session_end` (C5).
///
/// As on Android: one background `tugboat-stop` thread waits on a latch
/// with a deadline, then runs `finish` once. The caller's thread (main) only
/// posts `session.end`. Without a drain to wait for (the host is no longer
/// running, or the session already ended, so no `session_end` will be
/// posted) it finishes at once. The watcher's callback holds only the
/// latch, so nothing the runtime owns is kept alive through it, and it is
/// dropped once the wait ends.
final class StopSequence {
  /// The engine's `endDrainTimeoutMs` (5 s) plus one `jsonTimeoutMs`
  /// (15 s) for the `session_end` post itself, plus slack for its answer:
  /// past this nothing more will be delivered.
  static let defaultMaxDrain: TimeInterval = 25

  private let maxDrain: TimeInterval

  init(maxDrain: TimeInterval = StopSequence.defaultMaxDrain) {
    self.maxDrain = maxDrain
  }

  func run(watcher: SessionEndWatcher, awaitDrain: Bool, endSession: () -> Void, finish: @escaping () -> Void) {
    let settled = DispatchSemaphore(value: 0)
    if awaitDrain {
      watcher.whenSettled { settled.signal() }
    }
    endSession()
    let deadline: DispatchTime = awaitDrain ? .now() + maxDrain : .now()
    let thread = Thread { [weak watcher] in
      _ = settled.wait(timeout: deadline)
      watcher?.stopWaiting()
      finish()
    }
    thread.name = "tugboat-stop"
    thread.start()
  }
}

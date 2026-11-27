/// Runs a callback on the next display frame; `DisplayLinkFrames` in the
/// app, a manual scheduler in tests.
protocol FrameScheduler: AnyObject {
  /// Arms one callback for the next frame. Arming again before it runs is a
  /// no-op for the caller (`FactBatcher` arms at most once per frame).
  func scheduleFrame(_ callback: @escaping () -> Void)
  /// Stops the scheduler; a pending callback does not run.
  func invalidate()
}

/// Collects facts on the main thread and posts them once per frame as one
/// engine `batch` (native SDK note section 4). Each fact keeps its own time.
///
/// Hooks registered with `onFrame` run first on every frame, so producers
/// that settle on a frame boundary (scroll idleness, focus leaving) can add
/// their facts to the same batch. Main thread only.
final class FactBatcher {
  private weak var sink: FactSink?
  private let frames: FrameScheduler
  private var pending: [AdapterFact] = []
  private var frameRequested = false
  private var flushing = false
  private var frameHooks: [() -> Void] = []

  init(sink: FactSink, frames: FrameScheduler) {
    self.sink = sink
    self.frames = frames
  }

  /// Queues `fact` for the next frame. Facts a frame hook adds go out in
  /// the batch of the frame that ran it.
  func add(_ fact: AdapterFact) {
    pending.append(fact)
    if !flushing {
      requestFrame()
    }
  }

  /// `hook` runs before each flush; it may `add` facts. Keep it cheap.
  func onFrame(_ hook: @escaping () -> Void) {
    frameHooks.append(hook)
  }

  /// Requests a frame even with nothing pending, for hooks waiting on time.
  func requestFrame() {
    guard !frameRequested else { return }
    frameRequested = true
    frames.scheduleFrame { [weak self] in self?.flush() }
  }

  /// Posts everything pending now. Called by the frame callback and on stop.
  func flush() {
    frameRequested = false
    flushing = true
    for hook in frameHooks {
      hook()
    }
    flushing = false
    guard !pending.isEmpty else { return }
    let batch = pending.map { $0.message }
    pending.removeAll()
    sink?.postBatch(batch)
  }

  /// Flushes, then stops the frame scheduler.
  func close() {
    flush()
    frames.invalidate()
  }
}

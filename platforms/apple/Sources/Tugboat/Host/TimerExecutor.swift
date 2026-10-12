import Dispatch

/// Executes `timer.schedule` / `timer.cancel` with one `DispatchSourceTimer`
/// per timer id on the engine queue. The engine's `atMonoUs` is in the
/// `ProcessInfo.systemUptime` timebase (see `SystemHostClock`), which is the
/// mach uptime clock `DispatchTime(uptimeNanoseconds:)` uses.
///
/// Confined to `queue`; `onFired` runs there with the timer's deadline.
final class TimerExecutor {
  private let queue: DispatchQueue
  private let onFired: (_ timerId: String, _ atMonoUs: Int64) -> Void
  private var pending: [String: Armed] = [:]
  private var lastGeneration: UInt64 = 0

  /// One armed timer. `generation` tells a replaced timer's late event apart.
  private struct Armed {
    let source: DispatchSourceTimer
    let generation: UInt64
  }

  init(queue: DispatchQueue, onFired: @escaping (_ timerId: String, _ atMonoUs: Int64) -> Void) {
    self.queue = queue
    self.onFired = onFired
  }

  deinit {
    cancelAll()
  }

  var scheduledCount: Int {
    pending.count
  }

  /// Schedules `timerId`; an armed timer with the same id is replaced.
  func schedule(timerId: String, atMonoUs: Int64) {
    cancel(timerId: timerId)
    lastGeneration &+= 1
    let generation = lastGeneration
    let timer = DispatchSource.makeTimerSource(flags: [], queue: queue)
    timer.setEventHandler { [weak self] in
      self?.fire(timerId: timerId, generation: generation, atMonoUs: atMonoUs)
    }
    pending[timerId] = Armed(source: timer, generation: generation)
    timer.schedule(deadline: TimerExecutor.deadline(atMonoUs: atMonoUs), repeating: .never, leeway: .milliseconds(1))
    timer.resume()
  }

  func cancel(timerId: String) {
    pending.removeValue(forKey: timerId)?.source.cancel()
  }

  func cancelAll() {
    for armed in pending.values {
      armed.source.cancel()
    }
    pending.removeAll()
  }

  private func fire(timerId: String, generation: UInt64, atMonoUs: Int64) {
    // A replaced or cancelled timer whose event was already queued.
    guard let armed = pending[timerId], armed.generation == generation else { return }
    pending[timerId] = nil
    armed.source.cancel()
    onFired(timerId, atMonoUs)
  }

  /// One microsecond late, so converting nanoseconds to mach ticks (which
  /// rounds down) never lets the timer fire before `atMonoUs`.
  static func deadline(atMonoUs: Int64) -> DispatchTime {
    guard atMonoUs > 0 else { return DispatchTime(uptimeNanoseconds: 1) }
    let (nanos, overflow) = (UInt64(atMonoUs) + 1).multipliedReportingOverflow(by: 1000)
    return DispatchTime(uptimeNanoseconds: overflow ? UInt64.max : nanos)
  }
}

import Dispatch

/// Executes `timer.schedule` / `timer.cancel` with one `DispatchSourceTimer`
/// per timer id on the engine queue. The engine's `atMonoUs` is in the host
/// clock's timebase (`ProcessInfo.systemUptime`, see `SystemHostClock`). The
/// timer is armed for the remaining time from `DispatchTime.now()`, which
/// runs on the same mach uptime clock. The delay saturates, so no deadline
/// can overflow. The two clocks are read a moment apart, so a timer may fire
/// a hair early; `EngineHost` stamps a fire no earlier than its `atMonoUs`.
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
    let deadline = TimerExecutor.deadline(atMonoUs: atMonoUs, nowMonoUs: SystemHostClock().now().monoUs, now: .now())
    timer.schedule(deadline: deadline, repeating: .never, leeway: .milliseconds(1))
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

  /// `now` plus the time from `nowMonoUs` to `atMonoUs`, saturating: a past
  /// deadline is `now`, and a distant one never overflows. The delay is
  /// capped where its nanoseconds still fit in `Int64` (about 292 years), so
  /// nothing relies on Dispatch's own overflow handling.
  static func deadline(atMonoUs: Int64, nowMonoUs: Int64, now: DispatchTime) -> DispatchTime {
    let (remaining, overflow) = atMonoUs.subtractingReportingOverflow(nowMonoUs)
    let delayUs = overflow ? (atMonoUs < 0 ? Int64.min : Int64.max) : remaining
    guard delayUs > 0 else { return now }
    return now + .microseconds(Int(clamping: min(delayUs, maxDelayUs)))
  }

  static let maxDelayUs = Int64.max / 1000
}

import Foundation
import XCTest

@testable import Tugboat

/// Real `DispatchSourceTimer`s with short deadlines on the uptime clock.
final class TimerExecutorTests: XCTestCase {
  private struct Fire: Equatable {
    let timerId: String
    let atMonoUs: Int64
    let firedMonoUs: Int64
  }

  private let queue = TestQueues.engine()
  private let fires = Locked<[Fire]>([])
  private var timers: TimerExecutor!
  private let onFire = Locked<(() -> Void)?>(nil)

  override func setUp() {
    super.setUp()
    let fires = self.fires
    let onFire = self.onFire
    timers = TimerExecutor(queue: queue) { timerId, atMonoUs in
      XCTAssertTrue(TestQueues.onEngineQueue)
      let fire = Fire(timerId: timerId, atMonoUs: atMonoUs, firedMonoUs: SystemHostClock().now().monoUs)
      fires.withLock { $0.append(fire) }
      onFire.current?()
    }
  }

  override func tearDown() {
    queue.sync { timers.cancelAll() }
    timers = nil
    super.tearDown()
  }

  private func inMs(_ ms: Int64) -> Int64 {
    SystemHostClock().now().monoUs + ms * 1000
  }

  private func schedule(_ timerId: String, atMonoUs: Int64) {
    queue.sync { timers.schedule(timerId: timerId, atMonoUs: atMonoUs) }
  }

  /// Waits until `count` timers fired, then a little longer, and checks no
  /// extra timer fired. Past deadlines can fire before this is called, so the
  /// count check and the callback install run together on `queue`, where every
  /// fire is recorded. `timeout` is a progress wait, not a speed bound: CI runners stall for seconds.
  private func waitForFires(_ count: Int, timeout: TimeInterval = 30, settle: TimeInterval = 0.15) {
    if count > 0 {
      let done = expectation(description: "\(count) timers fired")
      done.assertForOverFulfill = false
      let fires = self.fires
      let onFire = self.onFire
      queue.sync {
        if fires.current.count >= count {
          done.fulfill()
        } else {
          onFire.withLock { $0 = { if fires.current.count >= count { done.fulfill() } } }
        }
      }
      wait(for: [done], timeout: timeout)
    }
    let settled = expectation(description: "settle")
    settled.isInverted = true
    wait(for: [settled], timeout: settle)
    onFire.withLock { $0 = nil }
    queue.sync {}
    XCTAssertEqual(fires.current.count, count, "exactly \(count) timers fired")
  }

  func testFiresAtOrAfterTheUptimeDeadline() {
    let due = inMs(100)
    schedule("flush", atMonoUs: due)
    waitForFires(1)

    let fire = fires.current.first
    XCTAssertEqual(fire?.timerId, "flush")
    XCTAssertEqual(fire?.atMonoUs, due)
    XCTAssertGreaterThanOrEqual(fire?.firedMonoUs ?? 0, due, "never early")
    XCTAssertEqual(queue.sync { timers.scheduledCount }, 0)
  }

  func testSchedulingTheSameIdReplacesThePreviousTimer() {
    schedule("flush", atMonoUs: inMs(50))
    let due = inMs(250)
    schedule("flush", atMonoUs: due)
    waitForFires(1)

    XCTAssertEqual(fires.current.count, 1, "fires once")
    XCTAssertGreaterThanOrEqual(fires.current.first?.firedMonoUs ?? 0, due)
  }

  func testCancelStopsOnlyThatTimer() {
    schedule("a", atMonoUs: inMs(50))
    schedule("b", atMonoUs: inMs(50))
    queue.sync {
      timers.cancel(timerId: "a")
      timers.cancel(timerId: "unknown")
    }
    waitForFires(1)
    XCTAssertEqual(fires.current.map { $0.timerId }, ["b"])
  }

  func testTimersFireInDeadlineOrder() {
    schedule("late", atMonoUs: inMs(90))
    schedule("early", atMonoUs: inMs(30))
    schedule("middle", atMonoUs: inMs(60))
    waitForFires(3)
    XCTAssertEqual(fires.current.map { $0.timerId }, ["early", "middle", "late"])
  }

  func testCancelAllClearsEverything() {
    schedule("a", atMonoUs: inMs(30))
    schedule("b", atMonoUs: inMs(60))
    queue.sync { timers.cancelAll() }
    waitForFires(0, settle: 0.3)

    XCTAssertTrue(fires.current.isEmpty)
    XCTAssertEqual(queue.sync { timers.scheduledCount }, 0)
  }

  func testDeadlinesAreRelativeToNowAndSaturate() {
    let now = DispatchTime(uptimeNanoseconds: 5_000_000_000)
    let nowMonoUs: Int64 = 5_000_000

    let soon = TimerExecutor.deadline(atMonoUs: nowMonoUs + 250_000, nowMonoUs: nowMonoUs, now: now)
    // Darwin stores mach ticks, so allow a microsecond of rounding.
    XCTAssertEqual(
      Double(soon.uptimeNanoseconds), Double(now.uptimeNanoseconds + 250_000_000), accuracy: 1_000)

    for past: Int64 in [nowMonoUs, nowMonoUs - 1, 0, -5, Int64.min] {
      XCTAssertEqual(TimerExecutor.deadline(atMonoUs: past, nowMonoUs: nowMonoUs, now: now), now, "\(past)")
    }
    XCTAssertEqual(TimerExecutor.deadline(atMonoUs: Int64.min, nowMonoUs: Int64.max, now: now), now)

    let year: UInt64 = 365 * 86_400 * 1_000_000_000
    for (atMonoUs, fromMonoUs) in [
      (Int64(7_000_000_000_000_000), nowMonoUs), (Int64.max, nowMonoUs), (Int64.max, Int64(-1)),
    ] {
      let far = TimerExecutor.deadline(atMonoUs: atMonoUs, nowMonoUs: fromMonoUs, now: now)
      XCTAssertGreaterThan(far.uptimeNanoseconds, now.uptimeNanoseconds + year, "\(atMonoUs)")
    }
  }

  func testDistantAndPastDeadlinesNeverTrap() {
    schedule("far", atMonoUs: 7_000_000_000_000_000)
    schedule("max", atMonoUs: Int64.max)
    schedule("negative", atMonoUs: -5)
    schedule("past", atMonoUs: 0)
    waitForFires(2)

    XCTAssertEqual(Set(fires.current.map { $0.timerId }), ["negative", "past"])
    XCTAssertEqual(queue.sync { timers.scheduledCount }, 2, "the distant timers stay armed")
  }

  /// A clock whose reading is fixed and unrelated to the system uptime.
  private struct FixedClock: HostClock {
    let monoUs: Int64
    func now() -> HostTime { HostTime(monoUs: monoUs, wallUs: 0) }
  }

  /// The delay is `atMonoUs` minus the injected clock's `now`, not the system
  /// uptime: a clock 1000 s ahead of the uptime still fires a timer 100 ms
  /// after it, where the system clock would make that timer 1000 s away.
  func testTimersFireByTheInjectedClock() {
    let fired = expectation(description: "fired")
    let startedUs = SystemHostClock().now().monoUs
    let ahead = FixedClock(monoUs: startedUs + 1_000_000_000)
    let firedAtUs = Locked<Int64>(0)
    let injected = TimerExecutor(queue: queue, clock: ahead) { _, _ in
      firedAtUs.withLock { $0 = SystemHostClock().now().monoUs }
      fired.fulfill()
    }
    queue.sync { injected.schedule(timerId: "t", atMonoUs: ahead.monoUs + 100_000) }
    wait(for: [fired], timeout: 30)
    XCTAssertGreaterThanOrEqual(firedAtUs.current - startedUs, 90_000, "not before the injected delay")
    XCTAssertLessThan(firedAtUs.current - startedUs, 30_000_000, "far short of the 1000 s the system clock would give")
    queue.sync { injected.cancelAll() }
  }

  /// A deadline already past by the injected clock fires at once, even when
  /// the system uptime would put it far in the future.
  func testADeadlinePastByTheInjectedClockFiresAtOnce() {
    let fired = expectation(description: "fired")
    let startedUs = SystemHostClock().now().monoUs
    let late = FixedClock(monoUs: startedUs + 1_000_000_000_000)
    let injected = TimerExecutor(queue: queue, clock: late) { _, _ in fired.fulfill() }
    queue.sync { injected.schedule(timerId: "t", atMonoUs: late.monoUs - 1) }
    wait(for: [fired], timeout: 30)
    queue.sync { injected.cancelAll() }
  }
}

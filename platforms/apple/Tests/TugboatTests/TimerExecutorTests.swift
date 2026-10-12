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
  /// fire is recorded.
  private func waitForFires(_ count: Int, timeout: TimeInterval = 2, settle: TimeInterval = 0.15) {
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

  func testPastDeadlinesFireAtOnce() {
    schedule("late", atMonoUs: 0)
    schedule("negative", atMonoUs: -5)
    waitForFires(2)
    XCTAssertEqual(Set(fires.current.map { $0.timerId }), ["late", "negative"])
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

  func testDeadlinesAreNeverEarlierThanAtMonoUs() {
    for atMonoUs: Int64 in [1, 999, 1_000_000, 81_234_567, 123_456_789_012] {
      XCTAssertGreaterThanOrEqual(
        TimerExecutor.deadline(atMonoUs: atMonoUs).uptimeNanoseconds, UInt64(atMonoUs) * 1000)
    }
    // Darwin's DispatchTime stores mach ticks, so tiny values read back
    // rounded to a tick (1 ns reads as 41 on Apple Silicon). Only require
    // that a negative time maps to a deadline already in the past.
    XCTAssertLessThanOrEqual(
      TimerExecutor.deadline(atMonoUs: -5).uptimeNanoseconds, DispatchTime.now().uptimeNanoseconds)
    XCTAssertEqual(TimerExecutor.deadline(atMonoUs: Int64.max).uptimeNanoseconds, UInt64.max)
  }
}

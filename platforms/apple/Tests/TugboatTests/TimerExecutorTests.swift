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

  /// Waits until `count` timers fired, then a little longer to catch extras.
  private func waitForFires(_ count: Int, timeout: TimeInterval = 2, settle: TimeInterval = 0.15) {
    let done = expectation(description: "\(count) timers fired")
    done.expectedFulfillmentCount = max(count, 1)
    done.assertForOverFulfill = false
    if count == 0 {
      done.isInverted = true
    }
    onFire.withLock { $0 = { done.fulfill() } }
    wait(for: [done], timeout: count == 0 ? settle : timeout)
    if count > 0 {
      let extra = expectation(description: "no more fires")
      extra.isInverted = true
      onFire.withLock { $0 = { extra.fulfill() } }
      wait(for: [extra], timeout: settle)
    }
    onFire.withLock { $0 = nil }
    queue.sync {}
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
    XCTAssertLessThanOrEqual(TimerExecutor.deadline(atMonoUs: -5).uptimeNanoseconds, 1)
    XCTAssertEqual(TimerExecutor.deadline(atMonoUs: Int64.max).uptimeNanoseconds, UInt64.max)
  }
}

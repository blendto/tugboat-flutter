#if canImport(UIKit)
import UIKit
import XCTest

@testable import Tugboat

/// Records begun and ended background tasks; `expire` runs the expiration
/// handlers as the system would.
final class FakeBackgroundTasks: BackgroundTasks {
  private struct State {
    var begun: [String] = []
    var ended: [UIBackgroundTaskIdentifier] = []
    var expirations: [() -> Void] = []
  }

  private let state = Locked(State())
  /// False stands in for an app extension or a refused request.
  var grants = true

  var begun: [String] { state.current.begun }
  var ended: [UIBackgroundTaskIdentifier] { state.current.ended }

  func begin(name: String, expired: @escaping () -> Void) -> UIBackgroundTaskIdentifier? {
    guard grants else { return nil }
    return state.withLock { (state: inout State) -> UIBackgroundTaskIdentifier in
      state.begun.append(name)
      state.expirations.append(expired)
      return UIBackgroundTaskIdentifier(rawValue: state.begun.count)
    }
  }

  func end(_ task: UIBackgroundTaskIdentifier) {
    state.withLock { $0.ended.append(task) }
  }

  func expire() {
    state.current.expirations.forEach { $0() }
  }
}

/// The background task around the `paused` flush (review of PR #100): begun
/// before the flush, ended exactly once.
final class BackgroundFlushTests: XCTestCase {
  private let tasks = FakeBackgroundTasks()

  func testTheTaskIsBegunBeforeTheFlushAndEndedWhenItIsDone() {
    var done: (() -> Void)?
    BackgroundFlush.run(tasks: tasks) { finish in
      XCTAssertEqual(self.tasks.begun, [BackgroundFlush.taskName])
      done = finish
    }
    XCTAssertEqual(tasks.ended, [])
    done?()
    XCTAssertEqual(tasks.ended, [UIBackgroundTaskIdentifier(rawValue: 1)])
  }

  func testAFlushWithNothingPendingEndsTheTaskAtOnce() {
    BackgroundFlush.run(tasks: tasks) { done in done() }
    XCTAssertEqual(tasks.ended, [UIBackgroundTaskIdentifier(rawValue: 1)])
  }

  func testExpirationEndsTheTaskAndALateDoneDoesNotEndItAgain() {
    var done: (() -> Void)?
    BackgroundFlush.run(tasks: tasks) { done = $0 }
    tasks.expire()
    XCTAssertEqual(tasks.ended, [UIBackgroundTaskIdentifier(rawValue: 1)])
    done?()
    done?()
    tasks.expire()
    XCTAssertEqual(tasks.ended, [UIBackgroundTaskIdentifier(rawValue: 1)])
  }

  func testDoneFromAnotherThreadEndsTheTaskOnce() {
    let ended = expectation(description: "done ran")
    BackgroundFlush.run(tasks: tasks) { done in
      DispatchQueue.global().async {
        done()
        done()
        ended.fulfill()
      }
    }
    wait(for: [ended], timeout: 30)
    XCTAssertEqual(tasks.ended, [UIBackgroundTaskIdentifier(rawValue: 1)])
  }

  /// An app extension, or a refused request: the flush still runs, and
  /// nothing is ended.
  func testWithoutATaskTheFlushStillRuns() {
    tasks.grants = false
    var flushed = false
    BackgroundFlush.run(tasks: tasks) { done in
      flushed = true
      done()
    }
    XCTAssertTrue(flushed)
    XCTAssertEqual(tasks.begun, [])
    XCTAssertEqual(tasks.ended, [])
  }
}
#endif

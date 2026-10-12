import Foundation
import XCTest

@testable import Tugboat

/// `SessionEndWatcher` and `StopSequence`: `engine.dispose` waits for the
/// `session_end` post to settle, bounded, without blocking the caller.
final class StopTests: XCTestCase {
  private let http = FakeHTTPSender()
  private lazy var watcher = SessionEndWatcher(delegate: http)

  private func lifecycle(_ eventType: String) -> HTTPRequest {
    HTTPRequest(
      requestId: "http-1", lane: "lifecycle", path: "/v1/sessions", timeoutMs: 1000,
      body: .json("{\"sessionId\":\"s\",\"eventType\":\"\(eventType)\"}"))
  }

  func testOnlyTheSessionEndLifecyclePostCounts() {
    XCTAssertTrue(SessionEndWatcher.isSessionEnd(lifecycle("session_end")))
    XCTAssertFalse(SessionEndWatcher.isSessionEnd(lifecycle("session_start")))
    let events = HTTPRequest(
      requestId: "http-2", lane: "events", path: "/v1/events/batch", timeoutMs: 1, body: .json("{\"eventType\":\"session_end\"}"))
    XCTAssertFalse(SessionEndWatcher.isSessionEnd(events))
  }

  func testRetriedOutcomesAreNotFinal() {
    XCTAssertTrue(SessionEndWatcher.isFinal(.http(status: 202, body: "")))
    XCTAssertTrue(SessionEndWatcher.isFinal(.http(status: 400, body: "")))
    for outcome in [TransportOutcome.http(status: 408, body: ""), .http(status: 429, body: ""), .http(status: 503, body: ""), .error, .timeout] {
      XCTAssertFalse(SessionEndWatcher.isFinal(outcome), "\(outcome)")
    }
  }

  func testFinishWaitsForTheSessionEndPost() {
    let finishes = Locked(0)
    var ended = false
    StopSequence(maxDrain: 30).run(
      watcher: watcher,
      endSession: { ended = true },
      finish: { finishes.withLock { $0 += 1 } })
    XCTAssertTrue(ended, "session.end is posted on the caller's thread")

    watcher.send(lifecycle("session_end")) { _ in }
    http.complete(0, .timeout)
    Thread.sleep(forTimeInterval: 0.2)
    XCTAssertEqual(finishes.current, 0, "a retried outcome keeps waiting")

    watcher.send(lifecycle("session_end")) { _ in }
    http.complete(1, .http(status: 202, body: "{}"))
    let deadline = Date().addingTimeInterval(2)
    while finishes.current == 0, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    XCTAssertEqual(finishes.current, 1)
  }

  func testFinishRunsOnceAfterTheDeadlineWithoutAPost() {
    let finished = expectation(description: "finish")
    finished.assertForOverFulfill = true
    StopSequence(maxDrain: 0.05).run(watcher: watcher, endSession: {}, finish: { finished.fulfill() })
    wait(for: [finished], timeout: 2)
    // A late settle does not finish again.
    watcher.send(lifecycle("session_end")) { _ in }
    http.complete(0, .http(status: 202, body: ""))
    let again = expectation(description: "no second finish")
    again.isInverted = true
    wait(for: [again], timeout: 0.1)
  }

  func testAnAlreadySettledPostFinishesAtOnce() {
    watcher.send(lifecycle("session_end")) { _ in }
    http.complete(0, .http(status: 202, body: ""))
    let finished = expectation(description: "finish")
    StopSequence(maxDrain: 30).run(watcher: watcher, endSession: {}, finish: { finished.fulfill() })
    wait(for: [finished], timeout: 2)
  }
}

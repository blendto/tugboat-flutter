import Foundation
import XCTest

@testable import Tugboat

/// `SessionEndWatcher` and `StopSequence`: `engine.dispose` waits for the
/// `session_end` post to settle, bounded, without blocking the caller.
final class StopTests: XCTestCase {
  /// Positive waits are progress waits, not speed bounds: CI runners stall for seconds.
  private static let progress: TimeInterval = 30
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

  /// `isFinal` repeats the engine's delivery rule; this pins the copy to
  /// the engine source and its conformance fixture, so a change there fails
  /// here and the watcher must follow.
  func testTheEngineStillClassifiesStatusesThisWay() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Sdk
      .deletingLastPathComponent()  // TugboatTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // apple
      .deletingLastPathComponent()  // platforms
      .deletingLastPathComponent()  // repository root
    let source = try String(
      contentsOf: root.appendingPathComponent("core/session-engine/src/transport.cpp"), encoding: .utf8)
    let classify = try XCTUnwrap(source.components(separatedBy: "Verdict classify(").dropFirst().first)
      .components(separatedBy: "\n}\n")[0]
    XCTAssertTrue(classify.contains("if (result.outcome != TransportOutcome::kHttp) {\n    return Verdict::kRetry;"))
    XCTAssertTrue(classify.contains("if (status == 202) {\n    return Verdict::kAccepted;"))
    XCTAssertTrue(classify.contains("if (status == 408 || status == 429 || status >= 500) {\n    return Verdict::kRetry;"))
    XCTAssertTrue(classify.contains("return Verdict::kDrop;"))
    let fixture = try String(
      contentsOf: root.appendingPathComponent("conformance/engine/scenario/delivery-status-classification.json"),
      encoding: .utf8)
    XCTAssertTrue(
      fixture.contains(
        "Only HTTP 202 is acceptance (C8 kept): 200, 201, 204, and every other 4xx drop the batch for good; "
          + "408, 429, 5xx, a transport error, and a timeout queue it for retry."))
  }

  func testRetriedOutcomesAreNotFinal() {
    for status in [200, 201, 202, 204, 302, 400, 401, 404, 413, 499] {
      XCTAssertTrue(SessionEndWatcher.isFinal(.http(status: status, body: "")), "\(status)")
    }
    for outcome in [TransportOutcome.http(status: 408, body: ""), .http(status: 429, body: ""), .http(status: 503, body: ""), .error, .timeout] {
      XCTAssertFalse(SessionEndWatcher.isFinal(outcome), "\(outcome)")
    }
  }

  func testFinishWaitsForTheSessionEndPost() {
    let finishes = Locked(0)
    var ended = false
    StopSequence(maxDrain: 30).run(
      watcher: watcher,
      awaitDrain: true,
      endSession: { ended = true },
      finish: { finishes.withLock { $0 += 1 } })
    XCTAssertTrue(ended, "session.end is posted on the caller's thread")

    watcher.send(lifecycle("session_end")) { _ in }
    http.complete(0, .timeout)
    Thread.sleep(forTimeInterval: 0.2)
    XCTAssertEqual(finishes.current, 0, "a retried outcome keeps waiting")

    watcher.send(lifecycle("session_end")) { _ in }
    http.complete(1, .http(status: 202, body: "{}"))
    let deadline = Date().addingTimeInterval(Self.progress)
    while finishes.current == 0, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    XCTAssertEqual(finishes.current, 1)
  }

  func testFinishRunsOnceAfterTheDeadlineWithoutAPost() {
    let finished = expectation(description: "finish")
    finished.assertForOverFulfill = true
    StopSequence(maxDrain: 0.05).run(watcher: watcher, awaitDrain: true, endSession: {}, finish: { finished.fulfill() })
    wait(for: [finished], timeout: Self.progress)
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
    StopSequence(maxDrain: 30).run(watcher: watcher, awaitDrain: true, endSession: {}, finish: { finished.fulfill() })
    wait(for: [finished], timeout: Self.progress)
  }

  func testWithoutADrainToAwaitItFinishesAtOnce() {
    let finished = expectation(description: "finish")
    var ended = false
    StopSequence(maxDrain: 30).run(
      watcher: watcher, awaitDrain: false, endSession: { ended = true }, finish: { finished.fulfill() })
    wait(for: [finished], timeout: Self.progress)
    XCTAssertTrue(ended)
  }

  /// `session_end` never settles: once the deadline passed and the host
  /// closed, nothing keeps the host, its HTTP sender, or its capture sink
  /// alive (no cycle through the watcher's callback).
  func testTheHostIsReleasedWhenSessionEndNeverSettles() {
    weak var weakHost: EngineHost?
    weak var weakWatcher: SessionEndWatcher?
    weak var weakCaptures: RecordingCaptureSink?
    let finished = expectation(description: "finish")
    do {
      let watcher = SessionEndWatcher(delegate: FakeHTTPSender())
      let captures = RecordingCaptureSink()
      let host = EngineHost(
        transport: FakeEngineTransport(), queue: TestQueues.engine(), http: watcher, frames: FrameHandleTable(),
        captures: captures)
      weakHost = host
      weakWatcher = watcher
      weakCaptures = captures
      // The post is sent and never answered.
      watcher.send(lifecycle("session_end")) { _ in }
      StopSequence(maxDrain: 0.05).run(
        watcher: watcher, awaitDrain: true, endSession: {},
        finish: {
          host.close()
          finished.fulfill()
        })
    }
    wait(for: [finished], timeout: Self.progress)
    let deadline = Date().addingTimeInterval(Self.progress)
    while weakHost != nil || weakWatcher != nil || weakCaptures != nil, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    XCTAssertNil(weakHost)
    XCTAssertNil(weakWatcher)
    XCTAssertNil(weakCaptures)
  }
}

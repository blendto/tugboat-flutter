import Foundation
import XCTest

@testable import Tugboat

/// Writing and deleting entries alongside the engine's requests (W11
/// design sections 3.2 and 4).
final class OutboxSenderTests: XCTestCase {
  private let harness = OutboxHarness()
  private let delegate = OutboxRecordingSender()
  private lazy var outbox = harness.outbox(epoch: "e1")
  private lazy var sender = OutboxSender(
    delegate: delegate, outbox: outbox, context: OutboxRequests.context, frameBytes: OutboxRequests.jpeg)

  private func send(_ request: HTTPRequest) {
    sender.send(request) { _ in }
  }

  func testTheEntryIsWrittenWithTheBodyAndNoApiKey() throws {
    send(OutboxRequests.lifecycle())
    XCTAssertEqual(outbox.snapshot().entries.count, 1)
    let dir = try XCTUnwrap(harness.directories.first)
    XCTAssertEqual(dir, outbox.dirName(key: "s1/l/session_start/2026-10-27T10:00:00.000Z", epoch: "e1"))
    let entry = harness.entry(dir)
    XCTAssertEqual(entry["v"] as? Int, 1)
    XCTAssertEqual(entry["key"] as? String, "s1/l/session_start/2026-10-27T10:00:00.000Z")
    XCTAssertEqual(entry["lane"] as? String, "lifecycle")
    XCTAssertEqual(entry["path"] as? String, "/v1/sessions")
    XCTAssertEqual(entry["sessionId"] as? String, "s1")
    XCTAssertEqual(entry["attempts"] as? Int, 1)
    XCTAssertEqual(entry["processEpoch"] as? String, "e1")
    XCTAssertEqual(entry["sdkVersion"] as? String, "0.1.0")
    let salt = try XCTUnwrap(try? Data(contentsOf: harness.root.deletingLastPathComponent().appendingPathComponent("salt")))
    XCTAssertEqual(
      entry["appIdentity"] as? String, OutboxDigest.hmacSHA256Hex(key: salt, message: OutboxRequests.context.identityInput))
    XCTAssertEqual(harness.file(dir, "body"), Data(jsonBody(OutboxRequests.lifecycle()).utf8))
    let everything = try XCTUnwrap(harness.file(dir, "entry.json")) + (harness.file(dir, "body") ?? Data())
    XCTAssertNil(String(decoding: everything, as: UTF8.self).range(of: "key-1"))
  }

  func testAnAcceptedOrDroppedAnswerDeletesTheEntry() {
    send(OutboxRequests.lifecycle())
    send(OutboxRequests.events(["a"]))
    send(OutboxRequests.events(["b"]))
    XCTAssertEqual(outbox.snapshot().entries.count, 3)
    delegate.complete(0, .http(status: 202, body: ""))
    delegate.complete(1, .http(status: 400, body: ""))
    delegate.complete(2, .http(status: 200, body: ""))
    XCTAssertEqual(outbox.snapshot().entries.count, 0)
    XCTAssertEqual(harness.directories, [])
  }

  func testARetriedAnswerKeepsTheEntry() {
    send(OutboxRequests.lifecycle())
    send(OutboxRequests.events(["a"]))
    send(OutboxRequests.events(["b"]))
    delegate.complete(0, .http(status: 503, body: ""))
    delegate.complete(1, .timeout)
    delegate.complete(2, .http(status: 429, body: ""))
    XCTAssertEqual(outbox.snapshot().entries.count, 3)
    XCTAssertEqual(harness.directories.count, 3)
  }

  /// Edge case 9: a late 202 for attempt N while N+1 is in flight.
  func testALateAcceptForAnEarlierAttemptDoesNotDelete() {
    send(OutboxRequests.lifecycle())
    send(OutboxRequests.lifecycle(id: "http-9"))
    delegate.complete(0, .http(status: 202, body: ""))
    XCTAssertEqual(outbox.snapshot().entries.map { $0.entry.attempts }, [2])
    delegate.complete(1, .http(status: 202, body: ""))
    XCTAssertEqual(outbox.snapshot().entries.count, 0)
  }

  /// Edge case 4: the entry holds the last body sent under its key.
  func testARetryWithAChangedBodyKeepsTheLastBody() throws {
    send(OutboxRequests.lifecycle(extra: ",\"userId\":\"u1\""))
    send(OutboxRequests.lifecycle(extra: ",\"userId\":\"u2\""))
    XCTAssertEqual(outbox.snapshot().entries.count, 1)
    let dir = try XCTUnwrap(harness.directories.first)
    XCTAssertEqual(
      harness.file(dir, "body"), Data(jsonBody(OutboxRequests.lifecycle(extra: ",\"userId\":\"u2\"")).utf8))
    XCTAssertEqual(harness.entry(dir)["attempts"] as? Int, 2)
  }

  /// Edge case 6: chunks re-form; a frame is written once, then only its
  /// attempt count changes.
  func testAFrameIsWrittenOnceAndLaterChunksOnlyCountAttempts() throws {
    var bytes = ["h1": Data("first-1".utf8), "h2": Data("first-2".utf8), "h3": Data("first-3".utf8)]
    let frameSender = OutboxSender(
      delegate: delegate, outbox: outbox, context: OutboxRequests.context, frameBytes: { bytes[$0] })
    frameSender.send(OutboxRequests.frames([1, 2])) { _ in }
    XCTAssertEqual(outbox.snapshot().entries.count, 2)
    bytes["h2"] = Data("second-2".utf8)
    frameSender.send(OutboxRequests.frames([2, 3])) { _ in }
    let entries = outbox.snapshot().entries
    XCTAssertEqual(entries.count, 3)
    let frame2 = outbox.dirName(key: "s1/f/2", epoch: "e1")
    XCTAssertEqual(harness.file(frame2, "frame.jpg"), Data("first-2".utf8))
    XCTAssertEqual(harness.entry(frame2)["attempts"] as? Int, 2)
    XCTAssertEqual(harness.entry(outbox.dirName(key: "s1/f/1", epoch: "e1"))["attempts"] as? Int, 1)
    let fields = try XCTUnwrap(harness.file(frame2, "fields.json"))
    XCTAssertTrue(String(decoding: fields, as: UTF8.self).contains("2.jpg"))
  }

  func testKeyedRequestsCarryTheDeliveryKeyAndOthersAreSentWithoutAnEntry() {
    send(OutboxRequests.frames([4, 5]))
    let unkeyed = HTTPRequest(
      requestId: "r", lane: "lifecycle", path: "/v1/sessions", timeoutMs: 1, body: .json("{\"sessionId\":\"s1\"}"))
    send(unkeyed)
    XCTAssertEqual(delegate.requests.map { $0.deliveryKey }, ["s1/f/4,s1/f/5", nil])
    XCTAssertEqual(delegate.requests[1], unkeyed)
    let snapshot = outbox.snapshot()
    XCTAssertEqual(snapshot.entries.count, 2)
    XCTAssertEqual(snapshot.unkeyed, 1)
  }

  /// Edge case 10: a read-only disk; delivery still works, failures counted.
  func testAWriteFailureIsCountedAndTheRequestIsStillSent() throws {
    try FileManager.default.createDirectory(at: harness.root, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: harness.root.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: harness.root.path) }
    send(OutboxRequests.lifecycle())
    XCTAssertEqual(delegate.requests.count, 1)
    let snapshot = outbox.snapshot()
    XCTAssertEqual(snapshot.writeFailures, 1)
    XCTAssertEqual(snapshot.entries.count, 0)
    delegate.complete(0, .http(status: 202, body: ""))
    XCTAssertEqual(outbox.snapshot().entries.count, 0)
  }

  /// Edge case 13: `close` (from `stop`) lets queued writes land first.
  func testCloseWaitsForQueuedWritesBeforeClosingTheExecutor() {
    let gate = DispatchSemaphore(value: 0)
    outbox.queue.async { gate.wait() }
    send(OutboxRequests.lifecycle())
    let closed = expectation(description: "closed")
    let onDiskAtClose = Locked([String]())
    DispatchQueue.global().async {
      self.sender.close()
      onDiskAtClose.withLock { $0 = self.harness.directories }
      closed.fulfill()
    }
    Thread.sleep(forTimeInterval: 0.1)
    XCTAssertFalse(delegate.closed)
    gate.signal()
    // A progress wait, not a speed bound: CI runners stall for seconds.
    wait(for: [closed], timeout: 30)
    XCTAssertTrue(delegate.closed)
    XCTAssertEqual(onDiskAtClose.current.count, 1)
  }

  /// Edge case 14: neither a slow disk nor a drainer request in flight
  /// delays an engine request.
  func testAnEngineRequestStartsAtOnceWhileTheDiskAndTheDrainerAreBusy() {
    let drainer = OutboxRecordingSender()
    let earlier = harness.outbox(epoch: "e0")
    OutboxSender(delegate: OutboxRecordingSender(), outbox: earlier, context: OutboxRequests.context, frameBytes: OutboxRequests.jpeg)
      .send(OutboxRequests.lifecycle(session: "s0")) { _ in }
    _ = earlier.snapshot()
    outbox.startReplay(sender: drainer, context: OutboxRequests.context)
    _ = outbox.snapshot()
    XCTAssertEqual(drainer.requests.count, 1)
    let gate = DispatchSemaphore(value: 0)
    outbox.queue.async { gate.wait() }
    // A sender that waited for the disk would wait for this.
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { gate.signal() }
    let started = Date()
    send(OutboxRequests.events(["a"]))
    XCTAssertEqual(delegate.requests.count, 1)
    XCTAssertLessThan(Date().timeIntervalSince(started), 0.05)
    XCTAssertEqual(drainer.requests.count, 1, "the replay is still in flight")
  }

  /// m3: after `stop` then `clearPendingData`, the stopped session's engine
  /// (still delivering) sends but writes nothing; a new sender writes again.
  func testASenderFromBeforeAWipeWritesNothingMore() {
    send(OutboxRequests.events(["a"]))
    outbox.wipe()
    send(OutboxRequests.lifecycle("session_end"))
    XCTAssertEqual(delegate.requests.count, 2)
    XCTAssertNil(delegate.requests[1].deliveryKey)
    XCTAssertEqual(outbox.snapshot().entries.count, 0)
    XCTAssertEqual(harness.directories, [])
    OutboxSender(delegate: delegate, outbox: outbox, context: OutboxRequests.context, frameBytes: OutboxRequests.jpeg)
      .send(OutboxRequests.lifecycle(session: "s2")) { _ in }
    XCTAssertEqual(outbox.snapshot().entries.count, 1)
  }

  private func jsonBody(_ request: HTTPRequest) -> String {
    if case let .json(text) = request.body { return text }
    return ""
  }
}

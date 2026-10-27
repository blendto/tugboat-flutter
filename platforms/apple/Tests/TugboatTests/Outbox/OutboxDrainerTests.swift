import Foundation
import XCTest

@testable import Tugboat

/// Replaying, expiring, and bounding entries (W11 design sections 3.3, 3.4,
/// and 4). Two `Outbox` instances over one directory stand for two
/// processes.
final class OutboxDrainerTests: XCTestCase {
  private let harness = OutboxHarness()

  /// The first process sends `requests` and never hears back (killed).
  private func killedProcess(_ requests: [HTTPRequest], context: OutboxContext = OutboxRequests.context) {
    let outbox = harness.outbox(epoch: "dead")
    let sender = OutboxSender(
      delegate: OutboxRecordingSender(), outbox: outbox, context: context, frameBytes: OutboxRequests.jpeg)
    for request in requests {
      sender.send(request) { _ in }
    }
    _ = outbox.snapshot()
  }

  private func replaying(_ context: OutboxContext = OutboxRequests.context) -> (Outbox, OutboxRecordingSender) {
    let outbox = harness.outbox(epoch: "live")
    let drainer = OutboxRecordingSender()
    outbox.startReplay(sender: drainer, context: context)
    _ = outbox.snapshot()
    return (outbox, drainer)
  }

  /// Edge case 2: a kill after the write, before the answer; the next
  /// process sends it once.
  func testAnEntryFromAKilledProcessIsReplayedOnce() throws {
    killedProcess([OutboxRequests.lifecycle()])
    let (outbox, drainer) = replaying()
    XCTAssertEqual(drainer.requests.count, 1)
    let replayed = try XCTUnwrap(drainer.requests.first)
    XCTAssertEqual(replayed.path, "/v1/sessions")
    XCTAssertEqual(replayed.lane, "lifecycle")
    XCTAssertEqual(replayed.body, OutboxRequests.lifecycle().body)
    XCTAssertEqual(replayed.deliveryKey, "s1/l/session_start/2026-10-27T10:00:00.000Z")
    drainer.complete(0, .http(status: 202, body: ""))
    let snapshot = outbox.snapshot()
    XCTAssertEqual(snapshot.entries.count, 0)
    XCTAssertEqual(harness.directories, [])
    XCTAssertEqual(drainer.requests.count, 1)
    XCTAssertEqual(
      harness.lines.current.last,
      "outbox pass replayed=1 expired=0 evicted=0 corrupt=0 identityMismatch=0 bytesOnDisk=0")
  }

  func testReplaysGoOldestFirstOneAtATimeAndAFrameIsAOneFrameUpload() throws {
    killedProcess([OutboxRequests.events(["a"])])
    harness.advance(ms: 10)
    killedProcess([OutboxRequests.frames([3])])
    let (outbox, drainer) = replaying()
    XCTAssertEqual(drainer.requests.map { $0.lane }, ["events"])
    drainer.complete(0, .http(status: 202, body: ""))
    _ = outbox.snapshot()
    XCTAssertEqual(drainer.requests.map { $0.lane }, ["events", "frames"])
    let frame = drainer.requests[1]
    guard case let .multipart(fields, parts) = frame.body else { return XCTFail("not multipart") }
    XCTAssertEqual(fields.map { $0.value }, ["s1", "3", "[{\"frameNo\":3,\"atMs\":1.50,\"note\":\"a,]}\\\"b\"}]"])
    XCTAssertEqual(parts.map { $0.filename }, ["3.jpg"])
    XCTAssertEqual(outbox.replayFrame(parts[0].handle), Data("jpeg-h3".utf8))
  }

  /// Edge cases 5 and 7: an entry the engine never confirmed stays, and is
  /// replayed once its session is no longer current.
  func testTheFirstSessionsEntriesAreReplayedWhenTheSecondSessionSends() {
    let outbox = harness.outbox(epoch: "live")
    let engine = OutboxRecordingSender()
    let drainer = OutboxRecordingSender()
    let first = OutboxSender(delegate: engine, outbox: outbox, context: OutboxRequests.context, frameBytes: OutboxRequests.jpeg)
    outbox.startReplay(sender: drainer, context: OutboxRequests.context)
    first.send(OutboxRequests.events(["a"], session: "s1")) { _ in }
    engine.complete(0, .http(status: 503, body: ""))
    XCTAssertEqual(outbox.snapshot().currentSession, "s1")
    XCTAssertEqual(drainer.requests.count, 0)
    let second = OutboxSender(delegate: engine, outbox: outbox, context: OutboxRequests.context, frameBytes: OutboxRequests.jpeg)
    second.send(OutboxRequests.lifecycle(session: "s2")) { _ in }
    XCTAssertEqual(outbox.snapshot().currentSession, "s2")
    XCTAssertEqual(drainer.requests.map { $0.lane }, ["events"])
    // A late send from the first session's draining engine does not take
    // the current session back.
    first.send(OutboxRequests.lifecycle("session_end", session: "s1")) { _ in }
    XCTAssertEqual(outbox.snapshot().currentSession, "s2")
  }

  /// Edge case 8: an orphan whose request is still in flight is skipped.
  func testAnOrphanWithARequestInFlightIsSkipped() {
    let outbox = harness.outbox(epoch: "live")
    let engine = OutboxRecordingSender()
    let drainer = OutboxRecordingSender()
    let first = OutboxSender(delegate: engine, outbox: outbox, context: OutboxRequests.context, frameBytes: OutboxRequests.jpeg)
    outbox.startReplay(sender: drainer, context: OutboxRequests.context)
    first.send(OutboxRequests.events(["a"], session: "s1")) { _ in }
    let second = OutboxSender(delegate: engine, outbox: outbox, context: OutboxRequests.context, frameBytes: OutboxRequests.jpeg)
    second.send(OutboxRequests.lifecycle(session: "s2")) { _ in }
    _ = outbox.snapshot()
    XCTAssertEqual(drainer.requests.count, 0)
    XCTAssertEqual(outbox.snapshot().entries.count, 2)
  }

  /// Edge case 11.
  func testCorruptAndUnknownVersionEntriesAreDeletedAndCounted() throws {
    killedProcess([OutboxRequests.lifecycle(), OutboxRequests.events(["a"]), OutboxRequests.events(["b"])])
    let dirs = harness.directories
    XCTAssertEqual(dirs.count, 3)
    try Data("not json".utf8).write(to: harness.root.appendingPathComponent(dirs[0]).appendingPathComponent("entry.json"))
    var future = harness.entry(dirs[1])
    future["v"] = 2
    try JSONSerialization.data(withJSONObject: future)
      .write(to: harness.root.appendingPathComponent(dirs[1]).appendingPathComponent("entry.json"))
    try FileManager.default.createDirectory(
      at: harness.root.appendingPathComponent("partial"), withIntermediateDirectories: true)
    let (outbox, drainer) = replaying()
    XCTAssertEqual(drainer.requests.count, 1)
    drainer.complete(0, .http(status: 202, body: ""))
    _ = outbox.snapshot()
    XCTAssertEqual(harness.directories, [])
    XCTAssertEqual(
      harness.lines.current.last,
      "outbox pass replayed=1 expired=0 evicted=0 corrupt=3 identityMismatch=0 bytesOnDisk=0")
  }

  /// Edge case 12: another key, app, or base URL; nothing is sent.
  func testAnotherAppIdentityIsDeletedWithoutSending() {
    killedProcess([OutboxRequests.lifecycle()])
    let rotated = OutboxContext(
      identityInput: Data("https://collector.test\ncom.example\nkey-2".utf8), bounds: .default, sdkVersion: "0.1.0")
    let (outbox, drainer) = replaying(rotated)
    XCTAssertEqual(drainer.requests.count, 0)
    XCTAssertEqual(outbox.snapshot().entries.count, 0)
    XCTAssertEqual(
      harness.lines.current.last,
      "outbox pass replayed=0 expired=0 evicted=0 corrupt=0 identityMismatch=1 bytesOnDisk=0")
  }

  func testAnEntryPastTheMaxAgeIsDeletedWithoutSending() {
    killedProcess([OutboxRequests.lifecycle()])
    harness.advance(ms: Int64(OutboxBounds.default.maxAgeMs) + 1)
    let (outbox, drainer) = replaying()
    XCTAssertEqual(drainer.requests.count, 0)
    XCTAssertEqual(outbox.snapshot().entries.count, 0)
    XCTAssertTrue(harness.lines.current.last?.contains("expired=1") ?? false)
  }

  func testARetriedReplayBacksOffHonoursRetryAfterAndExpiresAfterMaxAttempts() {
    var bounds = OutboxBounds.default
    bounds.maxAttempts = 3
    let context = OutboxContext(identityInput: OutboxRequests.context.identityInput, bounds: bounds, sdkVersion: "0.1.0")
    killedProcess([OutboxRequests.lifecycle()], context: context)
    let (outbox, drainer) = replaying(context)
    drainer.complete(0, .http(status: 503, body: "", retryAfter: "45"))
    XCTAssertEqual(outbox.snapshot().entries.map { $0.entry.attempts }, [2])
    XCTAssertEqual(harness.scheduled.current.map { $0.delayMs }, [45_000])
    XCTAssertEqual(drainer.requests.count, 1)
    harness.scheduled.current[0].work()
    _ = outbox.snapshot()
    XCTAssertEqual(drainer.requests.count, 2)
    drainer.complete(1, .timeout)
    XCTAssertEqual(outbox.snapshot().entries.count, 0)
    XCTAssertEqual(harness.directories, [])
    XCTAssertTrue(harness.lines.current.last?.contains("expired=1") ?? false)
  }

  func testAnEntryWithMaxAttemptsFromEarlierLaunchesExpires() {
    var bounds = OutboxBounds.default
    bounds.maxAttempts = 2
    let context = OutboxContext(identityInput: OutboxRequests.context.identityInput, bounds: bounds, sdkVersion: "0.1.0")
    killedProcess([OutboxRequests.lifecycle(), OutboxRequests.lifecycle(id: "again")], context: context)
    let (outbox, drainer) = replaying(context)
    XCTAssertEqual(drainer.requests.count, 0)
    XCTAssertEqual(outbox.snapshot().entries.count, 0)
  }

  /// Never any network while dormant: nothing before `startReplay`, and
  /// nothing after `stopReplay`, not even a backoff that fires later.
  func testNothingIsReplayedOutsideASession() {
    killedProcess([OutboxRequests.lifecycle(), OutboxRequests.events(["a"])])
    let outbox = harness.outbox(epoch: "live")
    let drainer = OutboxRecordingSender()
    let engine = OutboxSender(
      delegate: OutboxRecordingSender(), outbox: outbox, context: OutboxRequests.context, frameBytes: OutboxRequests.jpeg)
    engine.send(OutboxRequests.lifecycle(session: "s9")) { _ in }
    XCTAssertEqual(outbox.snapshot().entries.count, 3)
    XCTAssertEqual(drainer.requests.count, 0)
    outbox.startReplay(sender: drainer, context: OutboxRequests.context)
    _ = outbox.snapshot()
    drainer.complete(0, .http(status: 500, body: ""))
    _ = outbox.snapshot()
    outbox.stopReplay()
    harness.scheduled.current.forEach { $0.work() }
    engine.send(OutboxRequests.lifecycle(session: "s10")) { _ in }
    _ = outbox.snapshot()
    XCTAssertEqual(drainer.requests.count, 1)
    XCTAssertTrue(drainer.closed)
  }

  /// Bounds (section 3.4): orphans first, frames before events, never a
  /// lifecycle entry or a key with a request in flight.
  func testOverTheBoundsOrphanFramesGoFirstAndLifecycleStays() {
    killedProcess([OutboxRequests.lifecycle(), OutboxRequests.events(["a"]), OutboxRequests.frames([1])])
    var bounds = OutboxBounds.default
    bounds.maxEntries = 3
    let context = OutboxContext(identityInput: OutboxRequests.context.identityInput, bounds: bounds, sdkVersion: "0.1.0")
    let outbox = harness.outbox(epoch: "live")
    let engine = OutboxRecordingSender()
    let sender = OutboxSender(delegate: engine, outbox: outbox, context: context, frameBytes: OutboxRequests.jpeg)
    sender.send(OutboxRequests.frames([1], session: "s2")) { _ in }
    var keys = outbox.snapshot().entries.map { $0.entry.key }.sorted()
    XCTAssertEqual(keys.count, 3)
    XCTAssertFalse(keys.contains("s1/f/1"))
    sender.send(OutboxRequests.events(["z"], session: "s2")) { _ in }
    keys = outbox.snapshot().entries.map { $0.entry.key }.sorted()
    XCTAssertEqual(keys.count, 3)
    XCTAssertTrue(keys.contains("s1/l/session_start/2026-10-27T10:00:00.000Z"))
    XCTAssertTrue(keys.contains("s2/f/1"))
    XCTAssertFalse(keys.contains { $0.hasPrefix("s1/e/") })
    sender.send(OutboxRequests.events(["y"], session: "s2")) { _ in }
    // Only in-flight keys and the lifecycle entry are left: over the bound.
    XCTAssertEqual(outbox.snapshot().entries.count, 4)
  }

  /// Edge case 15 and `clearPendingData`: the wipe deletes every entry,
  /// after queued writes.
  func testWipeDeletesEveryEntryAfterQueuedWrites() {
    killedProcess([OutboxRequests.lifecycle()])
    let outbox = harness.outbox(epoch: "live")
    let sender = OutboxSender(
      delegate: OutboxRecordingSender(), outbox: outbox, context: OutboxRequests.context, frameBytes: OutboxRequests.jpeg)
    let gate = DispatchSemaphore(value: 0)
    outbox.queue.async { gate.wait() }
    sender.send(OutboxRequests.events(["a"], session: "s2")) { _ in }
    outbox.wipe()
    gate.signal()
    XCTAssertEqual(outbox.snapshot().entries.count, 0)
    XCTAssertEqual(harness.directories, [])
  }
}

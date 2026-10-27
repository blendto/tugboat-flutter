import Foundation
import XCTest

@testable import Tugboat

/// What the outbox does with what it finds on disk: the start sweep (bounds
/// hold while dormant), unreadable versus corrupt files, out-of-range
/// numbers, and the salt.
final class OutboxDiskTests: XCTestCase {
  private let harness = OutboxHarness()

  private func killedProcess(_ requests: [HTTPRequest]) {
    let outbox = harness.outbox(epoch: "dead")
    let sender = OutboxSender(
      delegate: OutboxRecordingSender(), outbox: outbox, context: OutboxRequests.context, frameBytes: OutboxRequests.jpeg)
    for request in requests {
      sender.send(request) { _ in }
    }
    _ = outbox.snapshot()
  }

  private func setMode(_ mode: Int, _ url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
  }

  /// M2: a start sweep (dormant included) deletes entries past the max age
  /// and corrupt ones, keeps the rest, and sends nothing.
  func testAStartSweepDeletesExpiredAndCorruptEntriesAndSendsNothing() throws {
    killedProcess([OutboxRequests.lifecycle(session: "old")])
    harness.advance(ms: 1_000)
    killedProcess([OutboxRequests.lifecycle(session: "new"), OutboxRequests.events(["a"])])
    let corrupt = try XCTUnwrap(harness.directories.first { harness.entry($0)["lane"] as? String == "events" })
    try Data("{".utf8).write(to: harness.root.appendingPathComponent(corrupt).appendingPathComponent("entry.json"))
    harness.advance(ms: Int64(OutboxBounds.default.maxAgeMs))
    let outbox = harness.outbox(epoch: "live")
    outbox.sweepAtStart(bounds: .default)
    let keys = outbox.snapshot().entries.map { $0.entry.sessionId }
    XCTAssertEqual(keys, ["new"])
    XCTAssertEqual(harness.directories.count, 1)
    XCTAssertEqual(
      harness.lines.current, ["outbox sweep replayed=0 expired=1 evicted=0 corrupt=1 identityMismatch=0 bytesOnDisk=\(outbox.snapshot().entries.first?.bytes ?? -1)"])
  }

  /// M2: the size and count bounds hold at a start sweep.
  func testAStartSweepEnforcesTheBounds() {
    killedProcess([OutboxRequests.lifecycle(), OutboxRequests.events(["a"]), OutboxRequests.frames([1, 2])])
    var bounds = OutboxBounds.default
    bounds.maxEntries = 2
    let outbox = harness.outbox(epoch: "live")
    outbox.sweepAtStart(bounds: bounds)
    XCTAssertEqual(outbox.snapshot().entries.map { $0.entry.lane }.sorted(), ["events", "lifecycle"])
    XCTAssertEqual(harness.directories.count, 2)
  }

  /// m1: an `entry.json` that exists but cannot be read (Data Protection
  /// before the first unlock) is skipped, kept, and replayed once readable.
  func testAnUnreadableEntryIsSkippedThenReplayedOnceReadable() throws {
    killedProcess([OutboxRequests.lifecycle()])
    let dir = try XCTUnwrap(harness.directories.first)
    let file = harness.root.appendingPathComponent(dir).appendingPathComponent("entry.json")
    try setMode(0o000, file)
    let outbox = harness.outbox(epoch: "live")
    let drainer = OutboxRecordingSender()
    outbox.startReplay(sender: drainer, context: OutboxRequests.context)
    _ = outbox.snapshot()
    XCTAssertEqual(harness.directories, [dir])
    XCTAssertEqual(drainer.requests.count, 0)
    XCTAssertTrue(harness.lines.current.last?.contains("corrupt=0") ?? false)
    try setMode(0o600, file)
    OutboxSender(delegate: OutboxRecordingSender(), outbox: outbox, context: OutboxRequests.context, frameBytes: OutboxRequests.jpeg)
      .send(OutboxRequests.lifecycle(session: "s2")) { _ in }
    _ = outbox.snapshot()
    XCTAssertEqual(drainer.requests.map { $0.deliveryKey?.hasPrefix("s1/") }, [true])
  }

  /// m1: an unreadable payload is skipped for the pass, not deleted.
  func testAnUnreadablePayloadIsSkippedNotDeleted() throws {
    killedProcess([OutboxRequests.lifecycle()])
    let dir = try XCTUnwrap(harness.directories.first)
    let body = harness.root.appendingPathComponent(dir).appendingPathComponent("body")
    try setMode(0o000, body)
    defer { try? setMode(0o600, body) }
    let outbox = harness.outbox(epoch: "live")
    let drainer = OutboxRecordingSender()
    outbox.startReplay(sender: drainer, context: OutboxRequests.context)
    _ = outbox.snapshot()
    XCTAssertEqual(drainer.requests.count, 0)
    XCTAssertEqual(harness.directories, [dir])
    XCTAssertEqual(
      harness.lines.current.last, "outbox pass replayed=0 expired=0 evicted=0 corrupt=0 identityMismatch=0 bytesOnDisk=\(outbox.snapshot().entries.first?.bytes ?? -1)")
  }

  /// m1: a salt that exists but cannot be read turns the outbox off for the
  /// process (no writes, no replay) and is never overwritten.
  func testAnUnreadableSaltTurnsTheOutboxOffAndIsKept() throws {
    killedProcess([OutboxRequests.lifecycle()])
    let salt = harness.root.deletingLastPathComponent().appendingPathComponent("salt")
    let before = try Data(contentsOf: salt)
    try setMode(0o000, salt)
    let outbox = harness.outbox(epoch: "live")
    let drainer = OutboxRecordingSender()
    let engine = OutboxRecordingSender()
    outbox.startReplay(sender: drainer, context: OutboxRequests.context)
    OutboxSender(delegate: engine, outbox: outbox, context: OutboxRequests.context, frameBytes: OutboxRequests.jpeg)
      .send(OutboxRequests.lifecycle(session: "s2")) { _ in }
    let snapshot = outbox.snapshot()
    XCTAssertEqual(engine.requests.count, 1, "delivery still works")
    XCTAssertEqual(drainer.requests.count, 0)
    XCTAssertEqual(snapshot.writeFailures, 1)
    XCTAssertEqual(snapshot.entries.map { $0.entry.sessionId }, ["s1"], "the pending entry is kept")
    try setMode(0o600, salt)
    XCTAssertEqual(try Data(contentsOf: salt), before)
  }

  /// Re-review n1: a readable salt of the wrong size is corrupt, not
  /// unreadable: it is replaced, so the outbox works again.
  func testAWrongSizeSaltIsReplaced() throws {
    let salt = harness.root.deletingLastPathComponent().appendingPathComponent("salt")
    try FileManager.default.createDirectory(at: salt.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: salt)
    let outbox = harness.outbox(epoch: "live")
    OutboxSender(delegate: OutboxRecordingSender(), outbox: outbox, context: OutboxRequests.context, frameBytes: OutboxRequests.jpeg)
      .send(OutboxRequests.lifecycle()) { _ in }
    let snapshot = outbox.snapshot()
    XCTAssertEqual(snapshot.writeFailures, 0)
    XCTAssertEqual(snapshot.entries.count, 1)
    XCTAssertEqual(try Data(contentsOf: salt).count, 32)
  }

  /// m2: numbers out of range make an entry corrupt; nothing traps.
  func testOutOfRangeNumbersMakeAnEntryCorrupt() throws {
    killedProcess([OutboxRequests.lifecycle(), OutboxRequests.events(["a"])])
    for dir in harness.directories {
      try harness.rewrite(dir) { entry in
        if entry["lane"] as? String == "lifecycle" {
          entry["createdAtWallMs"] = Int64.min
        } else {
          entry["attempts"] = Int.max
        }
      }
    }
    let outbox = harness.outbox(epoch: "live")
    let drainer = OutboxRecordingSender()
    outbox.startReplay(sender: drainer, context: OutboxRequests.context)
    _ = outbox.snapshot()
    XCTAssertEqual(drainer.requests.count, 0)
    XCTAssertEqual(harness.directories, [])
    XCTAssertTrue(harness.lines.current.last?.contains("corrupt=2") ?? false)
  }

  /// m4: an `entry.json` without its payload is deleted when scanned.
  func testAnEntryWithoutItsPayloadIsDeletedAtScan() throws {
    killedProcess([OutboxRequests.lifecycle()])
    let dir = try XCTUnwrap(harness.directories.first)
    try FileManager.default.removeItem(at: harness.root.appendingPathComponent(dir).appendingPathComponent("body"))
    let outbox = harness.outbox(epoch: "live")
    XCTAssertEqual(outbox.snapshot().entries.count, 0)
    XCTAssertEqual(harness.directories, [])
  }
}

#if canImport(UIKit)
import TugboatSessionEngine
import UIKit
import XCTest

@testable import Tugboat

/// `TugboatConfig.durableOutbox` on the facade: the wipe trigger (agreed by
/// Chinmay on 2026-10-27), `clearPendingData`, replay only while a session
/// runs, and the immediate flush on `paused`. Real engines; the collector
/// (port 9) refuses connections, so every request is retried.
final class TugboatOutboxTests: XCTestCase {
  private let recorder = EngineRecorder()
  private let harness = OutboxHarness()
  private lazy var outbox = harness.outbox(epoch: "live")
  private var previousOpen: (() -> EngineTransport?)?
  private var previousOutbox: Outbox?

  override func setUp() {
    super.setUp()
    previousOpen = TugboatRuntime.openTransport
    previousOutbox = Tugboat.outbox
    let recorder = self.recorder
    TugboatRuntime.openTransport = { recorder.open() }
    Tugboat.outbox = outbox
  }

  override func tearDown() {
    Tugboat.stop()
    drainMain()
    TugboatRuntime.openTransport = previousOpen ?? { EngineBridge.open() }
    Tugboat.outbox = previousOutbox
    super.tearDown()
  }

  private func config(enabled: Bool, durableOutbox: Bool) -> TugboatConfig {
    TugboatConfig(
      collector: .init(baseURL: URL(string: "http://127.0.0.1:9") ?? URL(fileURLWithPath: "/"), apiKey: "key"),
      app: .init(name: "Tests", version: "1.0", buildNumber: "1", appId: "com.tugboat.tests", installationId: "i-1"),
      enabled: enabled, trackHostingControllers: false, durableOutbox: durableOutbox)
  }

  /// An entry a killed earlier process left for this configuration.
  private func pendingEntry() {
    let host = HostConfig(
      collectorBaseURL: "http://127.0.0.1:9", apiKey: "key", appVersion: "1.0", appBuild: "1", appId: "com.tugboat.tests")
    let earlier = harness.outbox(epoch: "dead")
    OutboxSender(
      delegate: OutboxRecordingSender(), outbox: earlier, context: OutboxContext(host: host, bounds: .default),
      frameBytes: { _ in nil }
    ).send(OutboxRequests.lifecycle(session: "earlier")) { _ in }
    XCTAssertEqual(earlier.snapshot().entries.count, 1)
  }

  private func drainMain() {
    let drained = expectation(description: "main drained")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 2)
  }

  @discardableResult
  private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() > deadline { return false }
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return true
  }

  private var replays: [Int] {
    outbox.snapshot().entries.filter { $0.entry.processEpoch == "dead" }.map { $0.entry.replays }
  }

  func testAStartWithTheOutboxOffWipesPendingEntries() {
    pendingEntry()
    Tugboat.start(config(enabled: false, durableOutbox: false))
    drainMain()
    XCTAssertEqual(outbox.snapshot().entries.count, 0)
    XCTAssertEqual(harness.directories, [])
  }

  /// Dormant is not a wipe trigger, and nothing is sent while dormant.
  func testADormantStartKeepsPendingEntriesAndSendsNothing() {
    pendingEntry()
    Tugboat.start(config(enabled: false, durableOutbox: true))
    drainMain()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    XCTAssertEqual(replays, [0])
    XCTAssertEqual(outbox.snapshot().replayPasses, 0)
  }

  /// The age bound holds while dormant: a dormant start deletes an entry
  /// past `outboxMaxAgeMs`, and sends nothing.
  func testADormantStartDeletesEntriesPastTheMaxAge() {
    pendingEntry()
    harness.advance(ms: 2_000)
    var dormant = config(enabled: false, durableOutbox: true)
    dormant.outboxMaxAgeMs = 1_000
    Tugboat.start(dormant)
    drainMain()
    XCTAssertEqual(outbox.snapshot().entries.count, 0)
    XCTAssertEqual(harness.directories, [])
    XCTAssertEqual(outbox.snapshot().replayPasses, 0)
  }

  /// Replay runs while the session runs and stops at `deactivate`: the
  /// backoff that fires afterwards sends nothing.
  func testASessionReplaysPendingEntriesAndDeactivateStopsIt() {
    pendingEntry()
    Tugboat.start(config(enabled: false, durableOutbox: true))
    Tugboat.activate(activationRequestId: "act-1")
    XCTAssertTrue(
      eventually { self.harness.scheduled.current.count == 1 }, "replayed once, refused, backing off")
    XCTAssertEqual(replays, [1])
    Tugboat.deactivate()
    drainMain()
    harness.scheduled.current.forEach { $0.work() }
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    XCTAssertEqual(replays, [1], "no replay after deactivate")
  }

  func testClearPendingDataDeletesPendingEntries() {
    pendingEntry()
    Tugboat.clearPendingData()
    XCTAssertEqual(outbox.snapshot().entries.count, 0)
    XCTAssertEqual(harness.directories, [])
  }

  func testPausedFlushesAtOnceOnlyWithTheOutboxOn() {
    Tugboat.start(config(enabled: true, durableOutbox: true))
    XCTAssertTrue(eventually { !self.recorder.inputs(SessionMessages.sessionStart).isEmpty })
    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    XCTAssertTrue(eventually { self.recorder.messages.contains { $0.type == HostMessages.transportFlush && $0.ok } })
    Tugboat.stop()
    drainMain()
    let flushes = recorder.messages.filter { $0.type == HostMessages.transportFlush }.count
    Tugboat.start(config(enabled: true, durableOutbox: false))
    XCTAssertTrue(eventually { self.recorder.inputs(SessionMessages.sessionStart).count == 2 })
    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    XCTAssertTrue(eventually { self.recorder.inputs(SessionMessages.appLifecycle).count >= 2 })
    XCTAssertEqual(recorder.messages.filter { $0.type == HostMessages.transportFlush }.count, flushes)
  }
}
#endif

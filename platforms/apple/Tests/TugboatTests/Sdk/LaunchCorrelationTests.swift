#if canImport(UIKit)
import XCTest
@testable import Tugboat

final class LaunchCorrelationTests: XCTestCase {
  private var lines: [String] = []

  override func setUp() {
    super.setUp()
    LaunchCorrelation.resetForTests()
    lines = []
  }

  private func captureOptions(
    emit: Bool = true,
    accept: Bool = false,
    runId: String? = nil
  ) -> LaunchOptions {
    LaunchOptions(
      emitSceneInventory: emit,
      acceptActionContext: accept,
      automationRunId: runId
    )
  }

  private func correlation(
    sessionWallUs: Int64? = 1_781_827_200_000_000,
    state: TugboatLifecycleState = .active,
    activationRequestId: String? = nil,
    schedule: @escaping (_ delay: TimeInterval, _ block: @escaping () -> Void) -> DispatchWorkItem = { _, block in
      let work = DispatchWorkItem(block: block)
      block()
      return work
    }
  ) -> LaunchCorrelation {
    LaunchCorrelation(
      lifecycle: {
        LaunchCorrelation.Reading(state: state, activationRequestId: activationRequestId, sessionWallUs: sessionWallUs)
      },
      schedule: schedule,
      emit: { [unowned self] in self.lines.append($0) }
    )
  }

  /// A correlation whose reading the test changes, with HEALTH held until
  /// the test fires it.
  private final class Clock10s {
    var reading = LaunchCorrelation.Reading(state: .dormant, activationRequestId: nil, sessionWallUs: nil)
    var pending: (() -> Void)?
  }

  private func heldCorrelation(_ held: Clock10s) -> LaunchCorrelation {
    LaunchCorrelation(
      lifecycle: { held.reading },
      schedule: { _, block in
        held.pending = block
        return DispatchWorkItem {}
      },
      emit: { [unowned self] in self.lines.append($0) })
  }

  func testGatingRequiresSceneOrActionFlags() {
    XCTAssertFalse(captureOptions(emit: false, accept: false, runId: "x").captureRequested)
  }

  func testLaunchOncePerProcess() {
    let options = captureOptions()
    let first = correlation(sessionWallUs: 100)
    first.startIfNeeded(parsed: options)
    drainMain()
    let second = correlation(sessionWallUs: 200)
    second.startIfNeeded(parsed: options)
    drainMain()
    let launches = launchLines()
    XCTAssertEqual(launches.count, 1)
    XCTAssertTrue(launches.first?.contains("session-100") ?? false)
  }

  func testStopThenSecondStartDoesNotLogAgain() {
    let options = captureOptions(accept: true)
    let first = correlation(sessionWallUs: 50)
    first.startIfNeeded(parsed: options)
    drainMain()
    first.stop()
    let second = correlation(sessionWallUs: 60)
    second.startIfNeeded(parsed: options)
    drainMain()
    XCTAssertEqual(launchLines().count, 1)
  }

  func testHealthActiveIncludesSessionId() {
    let correlation = correlation(
      schedule: { delay, block in
        XCTAssertEqual(delay, 10)
        let work = DispatchWorkItem(block: block)
        block()
        return work
      }
    )
    correlation.startIfNeeded(parsed: captureOptions(accept: true))
    drainMain()
    XCTAssertEqual(lines.count, 2)
    XCTAssertTrue(lines[1].hasPrefix("TUGBOAT_HEALTH "))
    XCTAssertTrue(lines[1].contains("\"lifecycle\":\"active\""))
    XCTAssertTrue(lines[1].contains("\"captureSessionId\":\"session-"))
  }

  func testHealthDormantOmitsSessionId() {
    let correlation = correlation(sessionWallUs: nil, state: .dormant)
    correlation.startIfNeeded(parsed: captureOptions())
    drainMain()
    XCTAssertEqual(lines.count, 2)
    guard lines.count == 2 else { return }
    XCTAssertTrue(lines[1].contains("\"lifecycle\":\"dormant\""))
    XCTAssertFalse(lines[1].contains("captureSessionId"))
  }

  /// The HEALTH JSON: `lifecycle` is the state's name; `activationRequestId`
  /// when one is set; `captureSessionId` only while a session runs.
  func testHealthJSONShape() throws {
    func health(_ state: TugboatLifecycleState, _ id: String?, _ wall: Int64?) throws -> [String: Any] {
      let line = LaunchOptions.healthLine(lifecycle: state.rawValue, activationRequestId: id, sessionWallUs: wall)
      XCTAssertTrue(line.hasPrefix("TUGBOAT_HEALTH {"))
      let json = String(line.dropFirst("TUGBOAT_HEALTH ".count))
      return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
    XCTAssertEqual(try health(.dormant, nil, nil) as NSDictionary, ["lifecycle": "dormant"])
    XCTAssertEqual(
      try health(.active, "run-1", 7) as NSDictionary,
      ["lifecycle": "active", "activationRequestId": "run-1", "captureSessionId": "session-7"])
    XCTAssertEqual(try health(.starting, "x", nil) as NSDictionary, ["lifecycle": "starting", "activationRequestId": "x"])
    XCTAssertEqual(
      try health(.stopping, "x\"y", 7) as NSDictionary,
      ["lifecycle": "stopping", "activationRequestId": "x\"y", "captureSessionId": "session-7"])
  }

  /// HEALTH does not keep the correlation alive.
  func testHealthDoesNotHoldTheCorrelation() {
    let held = Clock10s()
    held.reading = LaunchCorrelation.Reading(state: .active, activationRequestId: "a", sessionWallUs: 5)
    weak var weakCorrelation: LaunchCorrelation?
    do {
      let correlation = heldCorrelation(held)
      weakCorrelation = correlation
      correlation.startIfNeeded(parsed: captureOptions())
      drainMain()
    }
    XCTAssertNil(weakCorrelation)
    held.pending?()
    XCTAssertEqual(lines.last, "TUGBOAT_HEALTH {\"lifecycle\":\"active\",\"activationRequestId\":\"a\",\"captureSessionId\":\"session-5\"}")
  }

  /// m1: a new activation id within ten seconds: HEALTH names the session
  /// running when it prints, with that session's id.
  func testHealthAfterANewIdNamesTheCurrentSession() {
    let held = Clock10s()
    held.reading = LaunchCorrelation.Reading(state: .active, activationRequestId: "a", sessionWallUs: 100)
    heldCorrelation(held).startIfNeeded(parsed: captureOptions())
    drainMain()
    XCTAssertTrue(lines.first?.contains("\"captureSessionId\":\"session-100\"") ?? false)
    held.reading = LaunchCorrelation.Reading(state: .active, activationRequestId: "b", sessionWallUs: 300)
    held.pending?()
    XCTAssertEqual(
      lines.last, "TUGBOAT_HEALTH {\"lifecycle\":\"active\",\"activationRequestId\":\"b\",\"captureSessionId\":\"session-300\"}")
  }

  /// m1: deactivated within ten seconds: dormant, no session id.
  func testHealthAfterDeactivateHasNoSessionId() {
    let held = Clock10s()
    held.reading = LaunchCorrelation.Reading(state: .active, activationRequestId: "a", sessionWallUs: 100)
    heldCorrelation(held).startIfNeeded(parsed: captureOptions())
    drainMain()
    held.reading = LaunchCorrelation.Reading(state: .dormant, activationRequestId: nil, sessionWallUs: nil)
    held.pending?()
    XCTAssertEqual(lines.last, "TUGBOAT_HEALTH {\"lifecycle\":\"dormant\"}")
  }

  /// As on Android: a running session whose engine host stopped reads
  /// `dormant` with no ids; a live one reads the lifecycle and its id.
  func testAStoppedHostReadsDormant() {
    var lifecycle = ActivationState.Snapshot()
    lifecycle.state = .active
    lifecycle.activationRequestId = "a"
    let stopped = LaunchCorrelation.Reading.of(lifecycle, session: (wallUs: 7, hostRunning: false))
    XCTAssertEqual(stopped.state, .dormant)
    XCTAssertNil(stopped.activationRequestId)
    XCTAssertNil(stopped.sessionWallUs)
    XCTAssertEqual(
      LaunchOptions.healthLine(
        lifecycle: stopped.state.rawValue, activationRequestId: stopped.activationRequestId,
        sessionWallUs: stopped.sessionWallUs),
      "TUGBOAT_HEALTH {\"lifecycle\":\"dormant\"}")
    let live = LaunchCorrelation.Reading.of(lifecycle, session: (wallUs: 7, hostRunning: true))
    XCTAssertEqual(live.state, .active)
    XCTAssertEqual(live.activationRequestId, "a")
    XCTAssertEqual(live.sessionWallUs, 7)
    let none = LaunchCorrelation.Reading.of(lifecycle, session: nil)
    XCTAssertEqual(none.state, .active)
    XCTAssertNil(none.sessionWallUs)
  }

  /// m2: a dormant start logs LAUNCH (no session id) and a dormant HEALTH.
  func testADormantStartLogsLaunchAndHealth() {
    let held = Clock10s()
    heldCorrelation(held).startIfNeeded(parsed: captureOptions(runId: "run-9"))
    drainMain()
    XCTAssertEqual(
      lines,
      ["TUGBOAT_LAUNCH {\"captureRequested\":true,\"emitSceneInventory\":true,\"acceptActionContext\":false,"
        + "\"automationRunId\":\"run-9\"}"])
    held.pending?()
    XCTAssertEqual(lines.last, "TUGBOAT_HEALTH {\"lifecycle\":\"dormant\"}")
    XCTAssertEqual(lines.count, 2)
  }

  func testAutomationRunIdEscapesControlCharacters() throws {
    let runId = "run\u{01}\"x"
    let line = captureOptions(runId: runId).launchLine(sessionWallUs: 1)
    let jsonPart = String(line.dropFirst("TUGBOAT_LAUNCH ".count))
    let object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(jsonPart.utf8)) as? [String: Any])
    XCTAssertEqual(object["automationRunId"] as? String, runId)
  }

  /// The default `schedule` runs HEALTH at once, so count LAUNCH lines only.
  private func launchLines() -> [String] {
    lines.filter { $0.hasPrefix("TUGBOAT_LAUNCH ") }
  }

  /// Runs the main queue until the blocks `LaunchCorrelation` posted have run.
  /// XCTest runs on main, so waiting on an expectation (which spins the run
  /// loop) is the only way to let them execute.
  private func drainMain() {
    let drained = expectation(description: "main queue drained")
    DispatchQueue.main.async { drained.fulfill() }
    // A progress wait, not a speed bound: CI runners stall for seconds.
    wait(for: [drained], timeout: 30)
  }
}
#endif

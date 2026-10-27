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
    sessionWallUs: Int64 = 1_781_827_200_000_000,
    state: TugboatLifecycleState = .active,
    activationRequestId: String? = nil,
    schedule: @escaping (_ delay: TimeInterval, _ block: @escaping () -> Void) -> DispatchWorkItem = { _, block in
      let work = DispatchWorkItem(block: block)
      block()
      return work
    }
  ) -> LaunchCorrelation {
    LaunchCorrelation(
      sessionWallUs: sessionWallUs,
      lifecycle: { (state, activationRequestId) },
      schedule: schedule,
      emit: { [unowned self] in self.lines.append($0) }
    )
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
    let correlation = correlation(state: .dormant)
    correlation.startIfNeeded(parsed: captureOptions())
    drainMain()
    XCTAssertEqual(lines.count, 2)
    guard lines.count == 2 else { return }
    XCTAssertTrue(lines[1].contains("\"lifecycle\":\"dormant\""))
    XCTAssertFalse(lines[1].contains("captureSessionId"))
  }

  /// The HEALTH JSON: `lifecycle` is the state's name; `activationRequestId`
  /// when one is set; no `captureSessionId` while dormant.
  func testHealthJSONShape() throws {
    func health(_ state: TugboatLifecycleState, _ id: String?) throws -> [String: Any] {
      let line = LaunchOptions.healthLine(lifecycle: state.rawValue, activationRequestId: id, sessionWallUs: 7)
      XCTAssertTrue(line.hasPrefix("TUGBOAT_HEALTH {"))
      let json = String(line.dropFirst("TUGBOAT_HEALTH ".count))
      return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
    XCTAssertEqual(try health(.dormant, nil) as NSDictionary, ["lifecycle": "dormant"])
    XCTAssertEqual(
      try health(.active, "run-1") as NSDictionary,
      ["lifecycle": "active", "activationRequestId": "run-1", "captureSessionId": "session-7"])
    XCTAssertEqual(
      try health(.starting, nil) as NSDictionary, ["lifecycle": "starting", "captureSessionId": "session-7"])
    XCTAssertEqual(
      try health(.stopping, "x\"y") as NSDictionary,
      ["lifecycle": "stopping", "activationRequestId": "x\"y", "captureSessionId": "session-7"])
  }

  /// HEALTH reads the lifecycle when it fires, not when LAUNCH was logged,
  /// and does not keep the correlation (the session's) alive.
  func testHealthReadsTheLifecycleWhenItFires() {
    var pending: (() -> Void)?
    var reading: (TugboatLifecycleState, String?) = (.active, "a")
    weak var weakCorrelation: LaunchCorrelation?
    do {
      let correlation = LaunchCorrelation(
        sessionWallUs: 5, lifecycle: { reading },
        schedule: { _, block in
          pending = block
          return DispatchWorkItem {}
        },
        emit: { [unowned self] in self.lines.append($0) })
      weakCorrelation = correlation
      correlation.startIfNeeded(parsed: captureOptions())
      drainMain()
    }
    XCTAssertNil(weakCorrelation, "the pending HEALTH line does not hold the session's correlation")
    reading = (.dormant, nil)
    pending?()
    XCTAssertEqual(lines.last, "TUGBOAT_HEALTH {\"lifecycle\":\"dormant\"}")
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
    wait(for: [drained], timeout: 2)
  }
}
#endif

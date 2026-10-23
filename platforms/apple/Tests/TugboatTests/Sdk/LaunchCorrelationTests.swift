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
    engineActive: Bool = true,
    schedule: @escaping (_ delay: TimeInterval, _ block: @escaping () -> Void) -> DispatchWorkItem = { _, block in
      let work = DispatchWorkItem(block: block)
      block()
      return work
    }
  ) -> LaunchCorrelation {
    LaunchCorrelation(
      sessionWallUs: sessionWallUs,
      isEngineActive: { engineActive },
      schedule: schedule,
      emit: { lines.append($0) }
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
    XCTAssertEqual(lines.count, 1)
    XCTAssertTrue(lines[0].contains("session-100"))
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
    XCTAssertEqual(lines.count, 1)
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
    let correlation = correlation(engineActive: false)
    correlation.startIfNeeded(parsed: captureOptions())
    drainMain()
    XCTAssertTrue(lines[1].contains("\"lifecycle\":\"dormant\""))
    XCTAssertFalse(lines[1].contains("captureSessionId"))
  }

  func testAutomationRunIdEscapesControlCharacters() {
    let runId = "run\u{01}\"x"
    let line = captureOptions(runId: runId).launchLine(sessionWallUs: 1)
    let jsonPart = String(line.dropFirst("TUGBOAT_LAUNCH ".count))
    let object = try! JSONSerialization.jsonObject(with: Data(jsonPart.utf8)) as! [String: Any]
    XCTAssertEqual(object["automationRunId"] as? String, runId)
  }

  private func drainMain() {
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.main.async { group.leave() }
    group.wait()
  }
}

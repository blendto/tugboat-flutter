import XCTest
@testable import Tugboat

final class TugboatLaunchArgumentsTests: XCTestCase {
  func testParseBareFlagsAndValues() {
    let parsed = TugboatLaunchArguments.parseArguments([
      "--tugboat-emit-scene-inventory",
      "--tugboat-automation-run-id=probe-2",
    ])
    XCTAssertEqual(parsed["emitSceneInventory"], "true")
    XCTAssertEqual(parsed["automationRunId"], "probe-2")
  }

  func testEnvironmentWinsOverArguments() {
    let merged = TugboatLaunchArguments.parse(
      environment: ["TUGBOAT_EMIT_SCENE_INVENTORY": "0"],
      arguments: ["--tugboat-emit-scene-inventory"])
    XCTAssertEqual(merged["emitSceneInventory"], "0")
  }

  func testParseBoolMatchesDart() {
    XCTAssertTrue(TugboatLaunchParsers.parseBool("1"))
    XCTAssertTrue(TugboatLaunchParsers.parseBool("YES"))
    XCTAssertFalse(TugboatLaunchParsers.parseBool("exploration"))
    XCTAssertFalse(TugboatLaunchParsers.parseBool(nil))
  }

  func testCaptureRequestedRequiresSceneOrActionFlags() {
    XCTAssertFalse(
      LaunchOptions(emitSceneInventory: false, acceptActionContext: false, automationRunId: "x").captureRequested)
    let options = LaunchOptions(emitSceneInventory: true, acceptActionContext: false, automationRunId: nil)
    XCTAssertTrue(options.captureRequested)
    XCTAssertTrue(options.launchLine(sessionWallUs: 42).contains("\"captureSessionId\":\"session-42\""))
  }
}

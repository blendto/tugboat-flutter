#if canImport(UIKit)
import UIKit
import XCTest

@testable import Tugboat

/// The public facade: idempotent start, refusal on missing `session_start`
/// fields, and lifecycle notifications to `app.lifecycle`.
final class TugboatFacadeTests: XCTestCase {
  private func config(version: String = "1.0", baseURL: String = "http://127.0.0.1:9") -> TugboatConfig {
    TugboatConfig(
      collector: .init(baseURL: URL(string: baseURL) ?? URL(fileURLWithPath: "/"), apiKey: "key"),
      app: .init(name: "Tests", version: version, buildNumber: "1", appId: "com.tugboat.tests", installationId: "i-1"),
      enabled: true,
      trackHostingControllers: false)
  }

  override func tearDown() {
    Tugboat.stop()
    drainMain()
    super.tearDown()
  }

  /// Runs what `stop` queued on the main thread, so the next test starts
  /// with no stored configuration.
  private func drainMain() {
    let drained = expectation(description: "main drained")
    DispatchQueue.main.async { drained.fulfill() }
    // A progress wait, not a speed bound: CI runners stall for seconds.
    wait(for: [drained], timeout: 30)
  }

  func testStartRefusesWithoutARequiredField() {
    Tugboat.start(config(version: " "))
    XCTAssertFalse(Tugboat.isRunning)
    Tugboat.start(config(baseURL: "file:///tmp"))
    XCTAssertFalse(Tugboat.isRunning, "a collector URL that is not http(s) is refused")
  }

  func testStartIsIdempotentAndStopEndsIt() {
    Tugboat.start(config())
    XCTAssertTrue(Tugboat.isRunning)
    Tugboat.start(config())
    XCTAssertTrue(Tugboat.isRunning)
    Tugboat.setUserId("user-1")
    Tugboat.setTraits(["plan": "pro"])
    Tugboat.setTraits(["bad": Double.infinity])
    Tugboat.stop()
    XCTAssertFalse(Tugboat.isRunning)
    Tugboat.stop()
  }

  func testEvidenceIsAdmittedOnlyWhileStarted() {
    let events = Tugboat.eventHook(source: "tests", parameterPolicy: .namesOnly)
    events.record("BEFORE_START")
    XCTAssertNil(EvidenceChannel.shared.admit())
    Tugboat.start(config())
    XCTAssertNotNil(EvidenceChannel.shared.admit())
    events.record("STARTED", parameters: ["k": 1])
    let call = Tugboat.beginNetworkCall(method: "GET", route: "/orders/1")
    call.complete(statusCode: 200)
    call.fail(.networkError)
    Tugboat.stop()
    XCTAssertNil(EvidenceChannel.shared.admit())
    Tugboat.beginNetworkCall(method: "GET", route: "/orders/2").complete(statusCode: 200)
  }

  func testCallsFromABackgroundThreadRunOnMain() {
    let done = expectation(description: "started from a background thread")
    DispatchQueue.global().async {
      Tugboat.start(self.config())
      DispatchQueue.main.async { done.fulfill() }
    }
    // A progress wait, not a speed bound: CI runners stall for seconds.
    wait(for: [done], timeout: 30)
    XCTAssertTrue(Tugboat.isRunning)
  }

  func testLifecycleNotificationsBecomeEngineStates() {
    let center = NotificationCenter()
    var states: [String] = []
    let bridge = AppLifecycleBridge(center: center) { states.append($0) }
    bridge.start()
    bridge.start()
    for name in [
      UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
      UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification,
      UIApplication.willTerminateNotification,
    ] {
      center.post(name: name, object: nil)
    }
    bridge.stop()
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    XCTAssertEqual(states, ["inactive", "paused", "inactive", "resumed", "detached"])
  }
}
#endif

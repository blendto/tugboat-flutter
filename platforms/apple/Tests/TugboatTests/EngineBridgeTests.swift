import Foundation
import TugboatSessionEngine
import XCTest

@testable import Tugboat

/// `EngineBridge` against the real engine linked through SwiftPM.
final class EngineBridgeTests: XCTestCase {
  private var bridge: EngineBridge!

  override func setUp() {
    super.setUp()
    bridge = EngineBridge.open()
    XCTAssertNotNil(bridge)
  }

  override func tearDown() {
    bridge?.close()
    bridge = nil
    super.tearDown()
  }

  private func submit(_ message: String) -> EngineResponse {
    bridge.submit(Data(message.utf8))
  }

  /// Same input and expected hash as conformance/fingerprint/label_hash/ascii.json.
  func testLabelHashMatchesTheConformanceFixture() {
    let response = submit("{\"type\":\"fingerprint.labelHash\",\"input\":{\"value\":\"Go\"}}")
    XCTAssertEqual(response.status, .ok)
    let result = jsonObject(response.text)["result"] as? [String: Any]
    XCTAssertEqual(result?["hash"] as? String, "6cc8519b91584e8b")
  }

  func testMalformedMessagesReturnTheErrorDocument() {
    let response = submit("{not json")
    XCTAssertEqual(response.status, .malformedMessage)
    let error = jsonObject(response.text)["error"] as? [String: Any]
    XCTAssertEqual(error?["status"] as? String, "malformed_message")
  }

  func testResponsesAreCopiedBeforeTheNextSubmit() {
    let first = submit("{\"type\":\"fingerprint.labelHash\",\"input\":{\"value\":\"Go\"}}")
    let firstText = first.text
    _ = submit("{\"type\":\"fingerprint.labelHash\",\"input\":{\"value\":\"a much longer label than before\"}}")
    _ = submit("{broken")
    XCTAssertEqual(first.text, firstText)
    XCTAssertTrue(firstText.contains("6cc8519b91584e8b"))
  }

  func testStatefulMessagesReachTheEngine() {
    XCTAssertEqual(submit("{\"type\":\"engine.configure\",\"input\":{}}").status, .ok)
    let snapshot = submit("{\"type\":\"session.snapshot\",\"input\":{}}")
    XCTAssertEqual(snapshot.status, .ok)
    let result = jsonObject(snapshot.text)["result"] as? [String: Any]
    XCTAssertTrue(result?["snapshot"] is NSNull, "no session yet")
  }

  func testUnknownTypesAreUnsupported() {
    XCTAssertEqual(submit("{\"type\":\"no.such.type\",\"input\":{}}").status, .unsupportedMessage)
  }

  func testSubmitAfterCloseIsAnInvalidArgument() {
    bridge.close()
    bridge.close()
    let response = submit("{\"type\":\"fingerprint.labelHash\",\"input\":{\"value\":\"Go\"}}")
    XCTAssertEqual(response.status, .invalidArgument)
    XCTAssertTrue(response.json.isEmpty)
  }

  func testStatusesMirrorTheCEnum() {
    let statuses: [tb_session_status] = [
      TB_SESSION_OK, TB_SESSION_INVALID_ARGUMENT, TB_SESSION_ABI_MISMATCH, TB_SESSION_MALFORMED_MESSAGE,
      TB_SESSION_INVALID_MESSAGE, TB_SESSION_UNSUPPORTED_MESSAGE, TB_SESSION_CONTRACT_MISMATCH,
      TB_SESSION_MESSAGE_TOO_LARGE, TB_SESSION_BUSY, TB_SESSION_OUT_OF_MEMORY, TB_SESSION_INTERNAL_ERROR,
    ]
    for status in statuses {
      let mapped = EngineStatus(code: Int(status.rawValue))
      XCTAssertEqual(mapped.rawValue, Int(status.rawValue))
      XCTAssertEqual(mapped.wireName, String(cString: tb_session_status_name(status)))
    }
    XCTAssertEqual(EngineStatus(code: 99), .internalError, "unknown codes count as internal errors")
  }

  /// The host driving the real engine: a stateless query and a rejected
  /// message leave it running.
  func testHostDrivesTheRealEngine() {
    guard let bridge = EngineBridge.open() else {
      return XCTFail("engine unavailable")
    }
    let queue = TestQueues.engine()
    let frames = FrameHandleTable()
    let http = FakeHTTPSender()
    let host = EngineHost(transport: bridge, queue: queue, http: http, frames: frames)
    let rejected = frames.put(Data([1]))

    host.postUntimed(type: "fingerprint.labelHash", inputJSON: "{\"value\":\"Go\"}")
    host.post(type: "no.such.type", inputJSON: "{}", at: SystemHostClock().now(), frameHandles: [rejected])
    queue.sync {}

    XCTAssertTrue(host.isRunning)
    XCTAssertNil(frames.get(rejected))
    XCTAssertTrue(http.requests.isEmpty)
    host.close()
    queue.sync {}
    XCTAssertFalse(host.isRunning)
  }
}

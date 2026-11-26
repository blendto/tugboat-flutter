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
    XCTAssertEqual(response.status, TB_SESSION_OK)
    let result = jsonObject(response.text)["result"] as? [String: Any]
    XCTAssertEqual(result?["hash"] as? String, "6cc8519b91584e8b")
  }

  func testMalformedMessagesReturnTheErrorDocument() {
    let response = submit("{not json")
    XCTAssertEqual(response.status, TB_SESSION_MALFORMED_MESSAGE)
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
    XCTAssertEqual(submit("{\"type\":\"engine.configure\",\"input\":{}}").status, TB_SESSION_OK)
    let snapshot = submit("{\"type\":\"session.snapshot\",\"input\":{}}")
    XCTAssertEqual(snapshot.status, TB_SESSION_OK)
    let result = jsonObject(snapshot.text)["result"] as? [String: Any]
    XCTAssertTrue(result?["snapshot"] is NSNull, "no session yet")
  }

  func testUnknownTypesAreUnsupported() {
    XCTAssertEqual(submit("{\"type\":\"no.such.type\",\"input\":{}}").status, TB_SESSION_UNSUPPORTED_MESSAGE)
  }

  func testSubmitAfterCloseIsAnInvalidArgument() {
    bridge.close()
    bridge.close()
    let response = submit("{\"type\":\"fingerprint.labelHash\",\"input\":{\"value\":\"Go\"}}")
    XCTAssertEqual(response.status, TB_SESSION_INVALID_ARGUMENT)
    XCTAssertTrue(response.json.isEmpty)
  }

  func testStatusNamesComeFromTheEngine() {
    XCTAssertEqual(submit("{broken").statusName, "malformed_message")
    XCTAssertEqual(EngineResponse(status: TB_SESSION_INTERNAL_ERROR, json: Data()).statusName, "internal_error")
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
    let host = EngineHost(transport: bridge, queue: queue, http: http, frames: frames, captures: RecordingCaptureSink())
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

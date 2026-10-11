import Foundation
import XCTest

import TugboatSessionEngine

/// Proves Swift reaches the session engine's C ABI directly through the
/// SwiftPM module (no Objective-C++ bridge), and that the engine built for
/// iOS produces the same output as the conformance fixtures.
final class SessionEngineABITests: XCTestCase {
  private var engine: OpaquePointer?

  override func setUp() {
    super.setUp()
    var config = tb_session_engine_config_v1(
      abi_version: UInt32(TB_SESSION_ENGINE_ABI_VERSION),
      max_depth: 0,
      max_message_bytes: 0
    )
    XCTAssertEqual(tb_session_engine_create_v1(&config, &engine), TB_SESSION_OK)
    XCTAssertNotNil(engine)
  }

  override func tearDown() {
    tb_session_engine_destroy(engine)
    engine = nil
    super.tearDown()
  }

  func testVersionsMatchHeader() {
    XCTAssertEqual(tb_session_engine_abi_version(), UInt32(TB_SESSION_ENGINE_ABI_VERSION))
    XCTAssertEqual(
      tb_session_engine_session_schema_version(),
      UInt32(TB_SESSION_ENGINE_SESSION_SCHEMA_VERSION))
    XCTAssertEqual(
      tb_session_engine_fingerprint_schema_version(),
      UInt32(TB_SESSION_ENGINE_FINGERPRINT_SCHEMA_VERSION))
    XCTAssertFalse(String(cString: tb_session_engine_version()).isEmpty)
  }

  /// Same input and expected hash as conformance/fingerprint/label_hash/ascii.json.
  func testLabelHashMatchesConformanceFixture() throws {
    let (status, response) = submit(#"{"type":"fingerprint.labelHash","input":{"value":"Go"}}"#)
    XCTAssertEqual(status, TB_SESSION_OK)
    let object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    let result = try XCTUnwrap(object["result"] as? [String: Any])
    XCTAssertEqual(result["hash"] as? String, "6cc8519b91584e8b")
  }

  func testMalformedMessageReturnsErrorDocument() throws {
    let (status, response) = submit("{not json")
    XCTAssertEqual(status, TB_SESSION_MALFORMED_MESSAGE)
    let object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    let error = try XCTUnwrap(object["error"] as? [String: Any])
    XCTAssertEqual(error["status"] as? String, "malformed_message")
  }

  func testAbiMismatchIsRejected() {
    var config = tb_session_engine_config_v1(
      abi_version: UInt32(TB_SESSION_ENGINE_ABI_VERSION) + 1,
      max_depth: 0,
      max_message_bytes: 0
    )
    var other: OpaquePointer?
    XCTAssertEqual(tb_session_engine_create_v1(&config, &other), TB_SESSION_ABI_MISMATCH)
    XCTAssertNil(other)
  }

  private func submit(_ message: String) -> (tb_session_status, String) {
    var out: UnsafePointer<CChar>?
    var outLength = 0
    let bytes = Array(message.utf8)
    let status = bytes.withUnsafeBufferPointer { buffer -> tb_session_status in
      buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
        tb_session_engine_submit_v1(engine, $0, buffer.count, &out, &outLength)
      }
    }
    // The engine owns `out` until the next submit/destroy; copy it now.
    let response = out.map { String(cString: $0) } ?? ""
    XCTAssertEqual(response.utf8.count, outLength)
    return (status, response)
  }
}

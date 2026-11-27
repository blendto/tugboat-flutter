import Foundation
import XCTest

@testable import Tugboat

/// Envelopes and host-written inputs are built by concatenation, so their
/// exact text is pinned here (and matches the Android host's `MessagesTest`).
final class MessagesTests: XCTestCase {
  private let at = HostTime(monoUs: 81_234_567, wallUs: 1_791_712_345_678_901)

  func testEnvelopeWrapsTheCallerInputVerbatim() {
    XCTAssertEqual(
      EngineMessage(type: "input.pointer", inputJSON: "{\"x\":390.0,\"y\":1e2}", at: at).json,
      "{\"type\":\"input.pointer\",\"at\":{\"monoUs\":81234567,\"wallUs\":1791712345678901},\"input\":{\"x\":390.0,\"y\":1e2}}"
    )
  }

  func testUntimedEnvelopesHaveNoAt() {
    XCTAssertEqual(
      EngineMessage(type: "engine.configure", inputJSON: "{}", at: nil).json,
      "{\"type\":\"engine.configure\",\"input\":{}}")
  }

  func testTypesAreQuoted() {
    XCTAssertEqual(EngineMessage(type: "a\"b", inputJSON: "{}", at: nil).json, "{\"type\":\"a\\\"b\",\"input\":{}}")
  }

  func testBatchWrapsMessagesInOrder() {
    XCTAssertEqual(
      EngineMessage.batchJSON([
        EngineMessage(type: "a", inputJSON: "{}", at: at),
        EngineMessage(type: "b", inputJSON: "{\"k\":1}", at: nil),
      ]),
      "{\"type\":\"batch\",\"messages\":[{\"type\":\"a\",\"at\":{\"monoUs\":81234567,\"wallUs\":1791712345678901},\"input\":{}},"
        + "{\"type\":\"b\",\"input\":{\"k\":1}}]}")
  }

  func testTimerFiredInputCarriesTheTimerId() {
    XCTAssertEqual(HostMessages.timerFiredInput(timerId: "flush\"1"), "{\"timerId\":\"flush\\\"1\"}")
    XCTAssertEqual(jsonObject(HostMessages.timerFiredInput(timerId: "flush\"1"))["timerId"] as? String, "flush\"1")
  }

  func testTransportResultInputs() {
    XCTAssertEqual(
      HostMessages.transportResultInput(requestId: "http-1", outcome: .timeout),
      "{\"requestId\":\"http-1\",\"outcome\":\"timeout\"}")
    XCTAssertEqual(
      HostMessages.transportResultInput(requestId: "http-2", outcome: .error),
      "{\"requestId\":\"http-2\",\"outcome\":\"error\"}")
    XCTAssertEqual(
      HostMessages.transportResultInput(requestId: "http-3", outcome: .http(status: 202, body: "{\"sessionId\":\"s\"}\n")),
      "{\"requestId\":\"http-3\",\"outcome\":\"http\",\"status\":202,\"body\":\"{\\\"sessionId\\\":\\\"s\\\"}\\n\"}")
  }

  func testQuotingEscapesWhatJSONRequires() {
    XCTAssertEqual(JSONText.quoted("a\\b\r\t\u{08}\u{0C}"), "\"a\\\\b\\r\\t\\b\\f\"")
    XCTAssertEqual(JSONText.quoted("\u{01}\u{1F}"), "\"\\u0001\\u001f\"")
    XCTAssertEqual(JSONText.quoted("café ✓ /"), "\"café ✓ /\"")
    let tricky = "q\"\\\n\u{00}é😀"
    let decoded = jsonObject("{\"v\":" + JSONText.quoted(tricky) + "}")["v"] as? String
    XCTAssertEqual(decoded, tricky)
  }

  func testHostTimeAndClock() {
    XCTAssertEqual(at.json, "{\"monoUs\":81234567,\"wallUs\":1791712345678901}")
    XCTAssertEqual(SystemHostClock.microseconds(1.5), 1_500_000)
    XCTAssertEqual(SystemHostClock.microseconds(-1), 0)
    XCTAssertEqual(SystemHostClock.microseconds(.nan), 0)

    let clock = SystemHostClock()
    let first = clock.now()
    let second = clock.now()
    XCTAssertGreaterThanOrEqual(second.monoUs, first.monoUs)
    XCTAssertEqual(
      Double(first.monoUs), ProcessInfo.processInfo.systemUptime * 1_000_000, accuracy: 1_000_000,
      "monoUs is systemUptime in microseconds")
    XCTAssertEqual(
      Double(first.wallUs), Date().timeIntervalSince1970 * 1_000_000, accuracy: 1_000_000,
      "wallUs is epoch microseconds")
  }

  func testCollectorHeadersKeepTheFlutterNamesAndOrder() {
    let config = HostConfig(
      collectorBaseURL: "http://x", apiKey: "pmk_key", appVersion: "1.2.3", appBuild: "42", appId: "com.example.app")
    XCTAssertEqual(
      config.collectorHeaders.map { $0.name },
      [
        "X-PMKit-API-Key", "X-Tugboat-API-Key", "X-Platform", "X-App-Build", "X-App-Version", "X-App-Id",
        "X-Sdk-Version",
      ])
    XCTAssertEqual(config.collectorHeaders.map { $0.value }, ["pmk_key", "pmk_key", "ios", "42", "1.2.3", "com.example.app", TugboatVersion.current])
    XCTAssertFalse(config.description.contains("pmk_key"), "description never prints the key")
  }
}

import Foundation
import XCTest

@testable import Tugboat

/// Outbox keys (W11 design section 3.1) and the wipe policy (section 3.5).
final class OutboxCaptureTests: XCTestCase {
  func testLifecycleKeyIsSessionEventTypeAndTriggeredAt() throws {
    let units = try XCTUnwrap(OutboxCapture.units(OutboxRequests.lifecycle("session_end"), frameBytes: OutboxRequests.jpeg))
    XCTAssertEqual(units.map { $0.key }, ["s1/l/session_end/2026-10-27T10:00:00.000Z"])
    XCTAssertEqual(units[0].sessionId, "s1")
    XCTAssertEqual(units[0].payload, .json(jsonText(OutboxRequests.lifecycle("session_end"))))
  }

  func testEventKeyIsTheDigestOfTheSortedIds() throws {
    let ab = try XCTUnwrap(OutboxCapture.units(OutboxRequests.events(["a", "b"]), frameBytes: OutboxRequests.jpeg))
    let ba = try XCTUnwrap(OutboxCapture.units(OutboxRequests.events(["b", "a"]), frameBytes: OutboxRequests.jpeg))
    let ac = try XCTUnwrap(OutboxCapture.units(OutboxRequests.events(["a", "c"]), frameBytes: OutboxRequests.jpeg))
    let digest = OutboxDigest.sha256Hex(Data("a\nb".utf8)).prefix(16)
    XCTAssertEqual(ab[0].key, "s1/e/\(digest)")
    XCTAssertEqual(ab[0].key, ba[0].key)
    XCTAssertNotEqual(ab[0].key, ac[0].key)
  }

  func testAFrameChunkIsOneUnitPerFrameWithItsOwnMetadataBytes() throws {
    let units = try XCTUnwrap(OutboxCapture.units(OutboxRequests.frames([7, 9]), frameBytes: OutboxRequests.jpeg))
    XCTAssertEqual(units.map { $0.key }, ["s1/f/7", "s1/f/9"])
    XCTAssertEqual(
      units[1].payload,
      .frame(
        fields: [
          FormField(name: "sessionId", value: "s1"),
          FormField(name: "frameNos", value: "9"),
          FormField(name: "frameMetadata", value: "[{\"frameNo\":9,\"atMs\":1.50,\"note\":\"a,]}\\\"b\"}]"),
        ],
        filename: "9.jpg", jpeg: Data("jpeg-h9".utf8)))
  }

  func testRequestsThatCannotBeKeyedHaveNoUnits() {
    let noTriggeredAt = HTTPRequest(
      requestId: "r", lane: "lifecycle", path: "/v1/sessions", timeoutMs: 1,
      body: .json("{\"sessionId\":\"s1\",\"eventType\":\"session_start\"}"))
    XCTAssertNil(OutboxCapture.units(noTriggeredAt, frameBytes: OutboxRequests.jpeg))
    let eventWithoutId = HTTPRequest(
      requestId: "r", lane: "events", path: "/v1/events/batch", timeoutMs: 1,
      body: .json("{\"events\":[{\"sessionId\":\"s1\"}]}"))
    XCTAssertNil(OutboxCapture.units(eventWithoutId, frameBytes: OutboxRequests.jpeg))
    XCTAssertNil(OutboxCapture.units(OutboxRequests.frames([1, 2]), frameBytes: { $0 == "h1" ? Data([1]) : nil }))
    let unknownLane = HTTPRequest(requestId: "r", lane: "other", path: "/x", timeoutMs: 1, body: .json("{}"))
    XCTAssertNil(OutboxCapture.units(unknownLane, frameBytes: OutboxRequests.jpeg))
  }

  func testJSONArrayTextSplitsTopLevelElementsVerbatim() {
    XCTAssertEqual(JSONArrayText.elements(" [ {\"a\":[1,2]} , \"x,]\\\"\" ,3.50 ] "), ["{\"a\":[1,2]}", "\"x,]\\\"\"", "3.50"])
    XCTAssertEqual(JSONArrayText.elements("[]"), [])
    XCTAssertNil(JSONArrayText.elements("{\"a\":1}"))
    XCTAssertNil(JSONArrayText.elements("[1,,2]"))
    XCTAssertNil(JSONArrayText.elements("[1,2"))
  }

  /// Agreed by Chinmay on 2026-10-27: dormant (`enabled` false) keeps the
  /// outbox; only `durableOutbox` false wipes it at `start`.
  func testOnlyDurableOutboxOffWipesAtStart() {
    let base = TugboatConfig(
      collector: .init(baseURL: URL(string: "https://collector.test")!, apiKey: "k"),
      app: .init(name: "n", version: "1", buildNumber: "1", appId: "a", installationId: "i"))
    var dormantDurable = base
    dormantDurable.durableOutbox = true
    dormantDurable.enabled = false
    XCTAssertFalse(OutboxPolicy.wipeAtStart(dormantDurable))
    var enabledDurable = dormantDurable
    enabledDurable.enabled = true
    XCTAssertFalse(OutboxPolicy.wipeAtStart(enabledDurable))
    XCTAssertTrue(OutboxPolicy.wipeAtStart(base))
    var enabledOff = base
    enabledOff.enabled = true
    XCTAssertTrue(OutboxPolicy.wipeAtStart(enabledOff))
  }

  func testConfigDefaultsKeepTheOutboxOffWithTheDesignBounds() {
    let config = TugboatConfig(
      collector: .init(baseURL: URL(string: "https://collector.test")!, apiKey: "k"),
      app: .init(name: "n", version: "1", buildNumber: "1", appId: "a", installationId: "i"))
    XCTAssertFalse(config.durableOutbox)
    XCTAssertEqual(OutboxPolicy.bounds(config), .default)
    XCTAssertEqual(OutboxBounds.default, OutboxBounds(maxBytes: 20_971_520, maxEntries: 1000, maxAgeMs: 259_200_000, maxAttempts: 8))
  }

  func testBackoffDoublesFromTwoSecondsAndHonoursRetryAfter() {
    XCTAssertEqual(OutboxBackoff.delayMs(attempts: 1, retryAfter: nil, nowWallMs: 0), 2_000)
    XCTAssertEqual(OutboxBackoff.delayMs(attempts: 3, retryAfter: nil, nowWallMs: 0), 8_000)
    XCTAssertEqual(OutboxBackoff.delayMs(attempts: 40, retryAfter: nil, nowWallMs: 0), 300_000)
    XCTAssertEqual(OutboxBackoff.delayMs(attempts: 1, retryAfter: " 30 ", nowWallMs: 0), 30_000)
    XCTAssertEqual(OutboxBackoff.delayMs(attempts: 1, retryAfter: "99999999999999999999", nowWallMs: 0), 300_000)
    // Sun, 06 Nov 1994 08:49:37 GMT is 784111777 s.
    XCTAssertEqual(
      OutboxBackoff.delayMs(attempts: 1, retryAfter: "Sun, 06 Nov 1994 08:49:37 GMT", nowWallMs: 784_111_717_000), 60_000)
    XCTAssertEqual(OutboxBackoff.delayMs(attempts: 1, retryAfter: "soon", nowWallMs: 0), 2_000)
  }

  private func jsonText(_ request: HTTPRequest) -> String {
    if case let .json(text) = request.body { return text }
    return ""
  }
}

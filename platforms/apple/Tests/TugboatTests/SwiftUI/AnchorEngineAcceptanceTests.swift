import Foundation
import TugboatSessionEngine
import XCTest

@testable import Tugboat

/// The engine's strict `targetAnchor` decoder accepts the anchors the SwiftUI
/// adapter writes, and carries `toolkit: "swiftui"` to the collector wire.
final class AnchorEngineAcceptanceTests: XCTestCase {
  private static let fixtureURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // SwiftUI
    .deletingLastPathComponent()  // TugboatTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // apple
    .deletingLastPathComponent()  // platforms
    .deletingLastPathComponent()  // repository root
    .appendingPathComponent("conformance/collector/event/generic-anchor-toolkit.json")

  func testTheEngineAcceptsAndForwardsAFullSwiftUIAnchor() throws {
    let anchor = TargetAnchor(
      widgetType: "UICollectionViewCell", role: nil,
      fingerprint: IdentityHash.fingerprint([(key: "routeKey", value: "Inbox"), (key: "path", value: "Scrollable#0/[item:0.2]/Cell#0")]),
      confidence: .medium,
      tagFingerprint: IdentityHash.fingerprint([(key: "routeKey", value: "Inbox"), (key: "tag", value: "row")]),
      routeKey: "Inbox", tag: "row", canonicalPath: "Scrollable#0/[item:0.2]/Cell#0",
      relativePosition: "center", enabled: nil, actions: ["tap"]
    )
    let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: AnchorEngineAcceptanceTests.fixtureURL)) as? [String: Any])
    var input = try XCTUnwrap(fixture["input"] as? [String: Any])
    var event = try XCTUnwrap(input["event"] as? [String: Any])
    event["targetAnchor"] = try XCTUnwrap(decodeObject(anchor.json.json))
    input["event"] = event
    let inputJSON = try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: input), encoding: .utf8))

    let bridge = try XCTUnwrap(EngineBridge.open())
    defer { bridge.close() }
    let response = bridge.submit(Data(("{\"type\":\"collector.event\",\"input\":" + inputJSON + "}").utf8))
    XCTAssertEqual(response.status, TB_SESSION_OK, response.text)
    let record = (decodeObject(response.text)?["result"] as? [String: Any])?["record"] as? [String: Any]
    let wire = try XCTUnwrap(record?["targetAnchor"] as? [String: Any], response.text)
    XCTAssertEqual(wire["toolkit"] as? String, "swiftui")
    XCTAssertEqual(wire["fingerprint"] as? String, anchor.fingerprint)
    XCTAssertEqual(wire["tagFingerprint"] as? String, anchor.tagFingerprint)
  }
}

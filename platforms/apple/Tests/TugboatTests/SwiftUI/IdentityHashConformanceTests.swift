import Foundation
import TugboatSessionEngine
import XCTest

@testable import Tugboat

/// `IdentityHash` against every `conformance/fingerprint/identity_parts`
/// vector, and against the engine's own `fingerprint.identityParts`.
final class IdentityHashConformanceTests: XCTestCase {
  private static let vectorsURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // SwiftUI
    .deletingLastPathComponent()  // TugboatTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // apple
    .deletingLastPathComponent()  // platforms
    .deletingLastPathComponent()  // repository root
    .appendingPathComponent("conformance/fingerprint/identity_parts")

  private struct Vector {
    let name: String
    let inputJSON: String
    let parts: [(key: String, value: String)]
    let canonicalString: String
    let fingerprint: String
  }

  private func vectors() throws -> [Vector] {
    let files = try FileManager.default.contentsOfDirectory(at: IdentityHashConformanceTests.vectorsURL, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    return try files.map { url in
      let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
      let input = try XCTUnwrap(object["input"] as? [String: Any])
      let expected = try XCTUnwrap(object["expected"] as? [String: Any])
      let rawParts = try XCTUnwrap(input["parts"] as? [[String]])
      let inputJSON = try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: input), encoding: .utf8))
      return Vector(
        name: url.lastPathComponent,
        inputJSON: inputJSON,
        parts: rawParts.compactMap { $0.count == 2 ? (key: $0[0], value: $0[1]) : nil },
        canonicalString: try XCTUnwrap(expected["canonicalString"] as? String),
        fingerprint: try XCTUnwrap(expected["fingerprint"] as? String)
      )
    }
  }

  func testEveryVectorMatches() throws {
    let all = try vectors()
    XCTAssertGreaterThanOrEqual(all.count, 13, "identity_parts vectors not found at \(IdentityHashConformanceTests.vectorsURL.path)")
    for vector in all {
      XCTAssertEqual(IdentityHash.canonicalString(vector.parts), vector.canonicalString, vector.name)
      XCTAssertEqual(IdentityHash.fingerprint(vector.parts), vector.fingerprint, vector.name)
    }
  }

  func testEveryVectorMatchesTheEngine() throws {
    let bridge = try XCTUnwrap(EngineBridge.open())
    defer { bridge.close() }
    for vector in try vectors() {
      let message = "{\"type\":\"fingerprint.identityParts\",\"input\":" + vector.inputJSON + "}"
      let response = bridge.submit(Data(message.utf8))
      XCTAssertEqual(response.status, TB_SESSION_OK, vector.name)
      let result = decodeObject(response.text)?["result"] as? [String: Any]
      XCTAssertEqual(result?["fingerprint"] as? String, IdentityHash.fingerprint(vector.parts), vector.name)
    }
  }

  func testAnchorsCarryTheToolkitOutsideTheHash() {
    let anchor = TargetAnchor(
      widgetType: "UITextField", role: "textField",
      fingerprint: IdentityHash.fingerprint([(key: "routeKey", value: "Checkout"), (key: "path", value: "TextField#0")]),
      confidence: .low, tagFingerprint: nil, routeKey: "Checkout", tag: nil, canonicalPath: "TextField#0",
      relativePosition: "top", enabled: true, actions: ["input", "tap"]
    )
    let json = decodeObject(anchor.json.json) ?? [:]
    XCTAssertEqual(json["toolkit"] as? String, "swiftui")
    XCTAssertEqual(json["schemaVersion"] as? Int, 6)
    XCTAssertEqual(json["fingerprintParts"] as? [String: String], ["schemaVersion": "6", "routeKey": "Checkout"])
    XCTAssertEqual(anchor.fingerprint, IdentityHash.fingerprint([(key: "path", value: "TextField#0"), (key: "routeKey", value: "Checkout")]))
  }
}

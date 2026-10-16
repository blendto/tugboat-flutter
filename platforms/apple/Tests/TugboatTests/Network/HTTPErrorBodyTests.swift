import Foundation
import XCTest

@testable import Tugboat

/// The byte-reading error-body rule (evidence-messages.md section 4.5) and
/// the route trimming the adapters share.
final class HTTPErrorBodyTests: XCTestCase {
  func testJSONMediaTypes() {
    let json = [
      "application/json", "Application/JSON", "application/json; charset=utf-8", " application/json ;q=1",
      "application/problem+json", "application/vnd.api+json", "text/x+JSON",
    ]
    let notJSON: [String?] = [
      nil, "", "text/plain", "application/jsonp", "application/json-seq", "json", "/+json", "application/",
      "application/+json/x", "text/html; profile=application/json",
    ]
    for type in json {
      XCTAssertTrue(HTTPErrorBody.isJSON(contentType: type), type)
    }
    for type in notJSON {
      XCTAssertFalse(HTTPErrorBody.isJSON(contentType: type), type ?? "nil")
    }
  }

  func testACompleteJSONBodyIsJSONTextAndAnythingElseIsText() {
    let body = Data("{\"error\":\"x\"}".utf8)
    XCTAssertEqual((HTTPErrorBody.body(bytes: body, contentType: "application/json") as? JSONTextBody)?.text, "{\"error\":\"x\"}")
    XCTAssertEqual(HTTPErrorBody.body(bytes: body, contentType: "text/plain") as? String, "{\"error\":\"x\"}")
    XCTAssertEqual(HTTPErrorBody.body(bytes: body, contentType: nil) as? String, "{\"error\":\"x\"}")
    XCTAssertNil(HTTPErrorBody.body(bytes: Data(), contentType: "application/json"), "an empty body gives none")
  }

  func testCompletenessIsDecidedAt65536Bytes() {
    let complete = Data(repeating: 0x20, count: HTTPErrorBody.completeBytes)
    let over = Data(repeating: 0x20, count: HTTPErrorBody.completeBytes + 1)
    XCTAssertTrue(HTTPErrorBody.body(bytes: complete, contentType: "application/json") is JSONTextBody)
    XCTAssertTrue(HTTPErrorBody.body(bytes: over, contentType: "application/json") is String)
    XCTAssertTrue(
      HTTPErrorBody.body(bytes: over + Data(repeating: 0x20, count: 100_000), contentType: "application/json") is String,
      "bytes past the peek are never read")
  }

  func testTextIsCutToWholeCharactersWithin4100Bytes() {
    XCTAssertEqual(HTTPErrorBody.text(Data(String(repeating: "a", count: 4100).utf8)).utf8.count, 4100)
    XCTAssertEqual(HTTPErrorBody.text(Data(String(repeating: "a", count: 4101).utf8)).utf8.count, 4100)
    // 4098 bytes of ASCII, then a 3-byte character crossing 4100: it is left out whole.
    let crossing = String(repeating: "a", count: 4098) + "€" + "tail"
    XCTAssertEqual(HTTPErrorBody.text(Data(crossing.utf8)), String(repeating: "a", count: 4098))
    // A 4-byte character ending exactly at 4100 is kept.
    let ending = String(repeating: "a", count: 4096) + "😀" + "tail"
    XCTAssertEqual(HTTPErrorBody.text(Data(ending.utf8)), String(repeating: "a", count: 4096) + "😀")
  }

  func testInvalidBytesBecomeReplacementCharactersCountedAsThreeBytes() {
    // Each lone 0xFF is one maximal subpart: one U+FFFD (3 bytes) each.
    let bytes = Data(repeating: 0xFF, count: 2000)
    let text = HTTPErrorBody.text(bytes)
    XCTAssertEqual(text.unicodeScalars.count, 1366)
    XCTAssertTrue(text.unicodeScalars.allSatisfy { $0 == "\u{FFFD}" })
    XCTAssertEqual(String(decoding: Data([0x61, 0xE2, 0x82, 0x62]), as: UTF8.self), "a\u{FFFD}b", "maximal subpart")
  }

  func testTheEncoderSendsJSONTextWhole() {
    XCTAssertEqual(
      EvidenceEncoder.errorResponseBody(JSONTextBody(text: "{\"a\":\"\u{1}\\\"\"}")),
      "{\"jsonText\":\"{\\\"a\\\":\\\"\\u0001\\\\\\\"\\\"}\"}")
    XCTAssertEqual(EvidenceEncoder.errorResponseBody("text"), "{\"value\":\"text\"}", "a string is still a text body")
  }

  func testRoutesAreTrimmedAsDartTrims() {
    XCTAssertEqual(NetworkRoute.trimmed("\u{FEFF}\u{3000} /orders/1 \u{2029}\u{85}"), "/orders/1")
    XCTAssertEqual(NetworkRoute.trimmed("/a b"), "/a b", "inner whitespace stays for the engine to reject")
    XCTAssertNil(NetworkRoute.trimmed(" \t\n"))
    XCTAssertNil(NetworkRoute.trimmed(""))
    XCTAssertNil(NetworkRoute.trimmed(nil))
    XCTAssertEqual(NetworkRoute.trimmed("\u{200B}/x"), "\u{200B}/x", "U+200B is not Dart whitespace")
    struct Failure: Error {}
    let request = URLRequest(url: URL(string: "https://example.test/x")!)
    XCTAssertNil(NetworkRoute.resolve({ _ in throw Failure() }, request))
    XCTAssertEqual(NetworkRoute.resolve({ $0.url?.path }, request), "/x")
  }
}

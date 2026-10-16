import Foundation
import XCTest

@testable import Tugboat

/// The multipart layout Dart's `http.MultipartRequest` writes, pinned by
/// `conformance/host/multipart-request.golden`, which the Android host's
/// `MultipartBodyTest` reads too.
final class MultipartBodyTests: XCTestCase {
  /// `<repo>/conformance/host/multipart-request.golden`, found from this file.
  private static let goldenURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // TugboatTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // apple
    .deletingLastPathComponent()  // platforms
    .deletingLastPathComponent()  // repository root
    .appendingPathComponent("conformance/host/multipart-request.golden")

  func testWritesTheSharedGoldenBytes() throws {
    let golden = try Data(contentsOf: MultipartBodyTests.goldenURL)
    let body = MultipartBody(
      fields: [
        FormField(name: "sessionId", value: "s-1"),
        FormField(name: "frameNos", value: "1,2"),
        FormField(name: "label", value: "café"),
        FormField(name: "a\"b\r\nc", value: "v"),
      ],
      files: [
        MultipartBody.File(field: "files", filename: "1.jpg", contentType: "image/jpeg", bytes: Data("JPEG".utf8)),
        MultipartBody.File(
          field: "files", filename: "2.jpg", contentType: "image/jpeg", bytes: Data([0xFF, 0xD8, 0x0D, 0x0A, 0xFF, 0xD9])),
      ],
      boundary: "b")

    XCTAssertEqual(body.contentType, "multipart/form-data; boundary=b")
    XCTAssertEqual(body.encoded(), golden)
  }

  func testNameEncodingCoversEveryNewlineForm() {
    XCTAssertEqual(MultipartBody.encode("a\"b\r\nc\rd\ne"), "a%22b%0D%0Ac%0D%0Ad%0D%0Ae")
  }

  func testBoundariesAreRandom() {
    let first = MultipartBody(fields: [], files: []).boundary
    let second = MultipartBody(fields: [], files: []).boundary
    XCTAssertEqual(first.count, 49)
    XCTAssertTrue(first.hasPrefix("tugboat-boundary-"))
    XCTAssertNotEqual(first, second)
  }
}

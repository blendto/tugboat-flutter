import Foundation
import XCTest

@testable import Tugboat

/// Golden bytes identical to the Android host's `MultipartBodyTest`, which
/// pins what Dart's `http.MultipartRequest` writes.
final class MultipartBodyTests: XCTestCase {
  private func text(_ body: MultipartBody) -> String {
    String(decoding: body.encoded(), as: UTF8.self)
  }

  func testWritesTheSameBytesAsDartMultipartRequest() {
    let body = MultipartBody(
      fields: [FormField(name: "sessionId", value: "s-1"), FormField(name: "frameNos", value: "7")],
      files: [MultipartBody.File(field: "files", filename: "7.jpg", contentType: "image/jpeg", bytes: Data("JPEG".utf8))],
      boundary: "b")

    XCTAssertEqual(body.contentType, "multipart/form-data; boundary=b")
    let expected =
      "--b\r\ncontent-disposition: form-data; name=\"sessionId\"\r\n\r\ns-1\r\n"
      + "--b\r\ncontent-disposition: form-data; name=\"frameNos\"\r\n\r\n7\r\n"
      + "--b\r\ncontent-type: image/jpeg\r\n"
      + "content-disposition: form-data; name=\"files\"; filename=\"7.jpg\"\r\n\r\nJPEG\r\n"
      + "--b--\r\n"
    XCTAssertEqual(body.encoded(), Data(expected.utf8))
  }

  func testNonASCIIFieldsDeclareUTF8LikeDart() {
    let body = MultipartBody(fields: [FormField(name: "label", value: "café")], files: [], boundary: "b")
    let expected =
      "--b\r\ncontent-disposition: form-data; name=\"label\"\r\n"
      + "content-type: text/plain; charset=utf-8\r\ncontent-transfer-encoding: binary\r\n\r\n"
      + "café\r\n--b--\r\n"
    XCTAssertEqual(body.encoded(), Data(expected.utf8))
  }

  func testNamesAreBrowserEncoded() {
    let body = MultipartBody(fields: [FormField(name: "a\"b\r\nc\rd\ne", value: "v")], files: [], boundary: "b")
    XCTAssertEqual(
      text(body),
      "--b\r\ncontent-disposition: form-data; name=\"a%22b%0D%0Ac%0D%0Ad%0D%0Ae\"\r\n\r\nv\r\n--b--\r\n")
  }

  func testFileBytesAreWrittenVerbatim() {
    let jpeg = Data([0xFF, 0xD8, 0x00, 0x0D, 0x0A, 0xFF])
    let body = MultipartBody(
      fields: [],
      files: [MultipartBody.File(field: "files", filename: "1.jpg", contentType: "image/jpeg", bytes: jpeg)],
      boundary: "b")
    var expected = Data(
      ("--b\r\ncontent-type: image/jpeg\r\n"
        + "content-disposition: form-data; name=\"files\"; filename=\"1.jpg\"\r\n\r\n").utf8)
    expected.append(jpeg)
    expected.append(Data("\r\n--b--\r\n".utf8))
    XCTAssertEqual(body.encoded(), expected)
  }

  func testBoundariesAreRandom() {
    let first = MultipartBody(fields: [], files: []).boundary
    let second = MultipartBody(fields: [], files: []).boundary
    XCTAssertEqual(first.count, 49)
    XCTAssertTrue(first.hasPrefix("tugboat-boundary-"))
    XCTAssertNotEqual(first, second)
  }
}

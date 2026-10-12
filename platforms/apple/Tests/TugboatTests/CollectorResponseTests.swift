import Foundation
import XCTest

@testable import Tugboat

/// Every outcome must be one the engine's `transport.result` accepts: a body
/// of at most 64 KiB of UTF-8 and a status in 100–599.
final class CollectorResponseTests: XCTestCase {
  private let limit = CollectorResponse.maxBodyBytes

  private func ascii(_ count: Int) -> String {
    String(repeating: "a", count: count)
  }

  func testShortBodiesPassThrough() {
    XCTAssertEqual(CollectorResponse.text(Data("{\"sessionId\":\"s-1\"} é😀".utf8)), "{\"sessionId\":\"s-1\"} é😀")
    XCTAssertEqual(CollectorResponse.text(Data()), "")
  }

  func testAFourByteCharacterStraddlingTheCutIsDropped() {
    for kept in 1...3 {
      let prefix = ascii(limit - kept)
      let text = CollectorResponse.text(Data((prefix + "😀tail").utf8))
      XCTAssertEqual(text, prefix, "\(kept) byte(s) of the character inside the limit")
      XCTAssertFalse(text.contains("\u{FFFD}"))
    }
  }

  func testShorterCharactersStraddlingTheCutAreDropped() {
    XCTAssertEqual(CollectorResponse.text(Data((ascii(limit - 1) + "é").utf8)), ascii(limit - 1))
    XCTAssertEqual(CollectorResponse.text(Data((ascii(limit - 2) + "€").utf8)), ascii(limit - 2))
    XCTAssertEqual(CollectorResponse.text(Data((ascii(limit - 1) + "€").utf8)), ascii(limit - 1))
  }

  func testACharacterEndingExactlyAtTheLimitIsKept() {
    let body = ascii(limit - 4) + "😀"
    XCTAssertEqual(CollectorResponse.text(Data((body + "more").utf8)), body)
    XCTAssertEqual(CollectorResponse.text(Data(ascii(limit + 10).utf8)).utf8.count, limit)
  }

  func testInvalidBytesNeverGrowPastTheLimit() {
    let text = CollectorResponse.text(Data(repeating: 0xFF, count: limit + 100))
    XCTAssertLessThanOrEqual(text.utf8.count, limit)
    XCTAssertFalse(text.isEmpty)
  }

  func testStatusesOutsideTheEngineRangeAreErrors() {
    for status in [-1, 0, 99, 600, 1_000] {
      XCTAssertEqual(CollectorResponse.outcome(status: status, body: Data("x".utf8)), .error, "\(status)")
    }
    for status in [100, 202, 400, 599] {
      XCTAssertEqual(
        CollectorResponse.outcome(status: status, body: Data("x".utf8)), .http(status: status, body: "x"), "\(status)")
    }
  }
}

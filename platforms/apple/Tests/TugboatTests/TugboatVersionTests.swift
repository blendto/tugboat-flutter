import Foundation
import XCTest

@testable import Tugboat

/// `TugboatVersion.current` is the single source of the SDK version; the
/// changelog must name it as its newest entry.
final class TugboatVersionTests: XCTestCase {
  func testTheNewestChangelogEntryIsTheCurrentVersion() throws {
    let changelog = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // TugboatTests
      .deletingLastPathComponent()  // Tests
      .appendingPathComponent("../Sources/Tugboat/CHANGELOG.md")
      .standardizedFileURL
    let text = try String(contentsOf: changelog, encoding: .utf8)
    let newest = text.components(separatedBy: "\n").first { $0.hasPrefix("## ") }
    XCTAssertEqual(newest, "## \(TugboatVersion.current)")
  }
}

import XCTest

@testable import Tugboat

/// The per-frame mask summary: which mode applied, and why.
final class MaskCoverageTests: XCTestCase {
  func testEveryFallbackIsAWholeFrameWithItsReason() {
    let cases: [(MaskFallback, MaskCoverage.Reason)] = [
      (.noWindow, .noWindowSize),
      (.unverifiedLayerAllowlist(iOSMajor: 18), .unverifiedLayerAllowlist),
      (.walkLimitExceeded, .walkExhausted),
      (.animating, .animating),
    ]
    for (fallback, reason) in cases {
      var stats = MaskStats()
      stats.representableBoxes = 1
      let coverage = MaskResult.wholeFrame(fallback, stats: stats).coverage
      XCTAssertEqual(coverage, MaskCoverage(mode: .wholeFrame, reasons: [reason]), "\(fallback)")
    }
  }

  func testAPreciseFrameListsItsFailClosedBoxesInOrder() {
    var stats = MaskStats()
    stats.unclassifiedLayers = 2
    stats.webViewBoxes = 1
    stats.rendererBoxes = 3
    stats.representableBoxes = 1
    let coverage = MaskResult(rects: [], fallback: nil, stats: stats).coverage
    XCTAssertEqual(coverage.mode, .precise)
    XCTAssertEqual(coverage.reasons, [.representable, .webView, .renderer, .unclassifiedLayer])
  }

  func testAPreciseFrameWithoutBoxesHasNoReasons() {
    var stats = MaskStats()
    stats.textLayers = 4
    stats.imageLayers = 1
    XCTAssertEqual(MaskResult(rects: [], fallback: nil, stats: stats).coverage, MaskCoverage(mode: .precise, reasons: []))
  }

  func testTheVocabularyIsClosed() {
    XCTAssertEqual(
      MaskCoverage.Reason.allCases.map { $0.rawValue },
      ["noWindowSize", "unverifiedLayerAllowlist", "walkExhausted", "animating", "representable", "webView", "renderer", "unclassifiedLayer"]
    )
    XCTAssertEqual([MaskCoverage.Mode.precise.rawValue, MaskCoverage.Mode.wholeFrame.rawValue], ["precise", "wholeFrame"])
  }
}

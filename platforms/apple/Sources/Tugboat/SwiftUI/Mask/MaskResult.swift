#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// One mask rectangle normalized to the window's bounds (x, y, width,
/// height in [0, 1]), the rule `TugboatCaptureRuntime.NormalizedMask`
/// applies when the capture wiring hands it over.
struct MaskRect: Equatable {
  static let fullFrame = MaskRect(x: 0, y: 0, width: 1, height: 1)

  let x: Double
  let y: Double
  let width: Double
  let height: Double

  /// `rect` (in `bounds` coordinates) clipped to `bounds` and normalized;
  /// nil when nothing of it is inside.
  init?(_ rect: CGRect, in bounds: CGRect) {
    guard bounds.width > 0, bounds.height > 0 else { return nil }
    let clipped = rect.intersection(bounds)
    guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
    let x = Double((clipped.minX - bounds.minX) / bounds.width)
    let y = Double((clipped.minY - bounds.minY) / bounds.height)
    let width = Double(clipped.width / bounds.width)
    let height = Double(clipped.height / bounds.height)
    guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else { return nil }
    self.init(x: x, y: y, width: width, height: height)
  }

  init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

/// Why a whole frame was masked instead of per region.
enum MaskFallback: Equatable {
  /// The window has no size, or is not attached.
  case noWindow
  /// The running iOS major has no verified SwiftUI layer allowlist and the
  /// window contains a hosting view.
  case unverifiedLayerAllowlist(iOSMajor: Int)
  /// The view or layer walk hit its budget before covering the window.
  case walkBudgetExceeded
}

/// What the mask walk found, for diagnostics and the allowlist regression
/// guard.
struct MaskStats: Equatable {
  var hostingViews = 0
  var textLayers = 0
  var imageLayers = 0
  var unclassifiedLayers = 0
  var uiKitText = 0
  var uiKitImages = 0
  var failClosedViews = 0
  /// Class names of unclassified layers with contents, with counts.
  var unclassifiedClasses: [String: Int] = [:]
}

/// The masks for one capture under `allTextAndMedia` (native SDK note 2.1).
/// `fallback` is set when the whole frame is masked because the screen
/// could not be enumerated with confidence; a frame is never sent unmasked.
struct MaskResult: Equatable {
  let rects: [MaskRect]
  let fallback: MaskFallback?
  let stats: MaskStats

  static func wholeFrame(_ fallback: MaskFallback, stats: MaskStats = MaskStats()) -> MaskResult {
    MaskResult(rects: [.fullFrame], fallback: fallback, stats: stats)
  }
}

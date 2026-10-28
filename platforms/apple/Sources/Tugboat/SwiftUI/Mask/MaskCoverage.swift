/// Which masking mode applied to one frame, for the host to report per frame
/// (forwarded on `capture.result`, recorded by the engine as a
/// `capture_diagnostic`). A closed vocabulary; no other values are sent.
struct MaskCoverage: Equatable {
  /// `precise`: masks per region. `wholeFrame`: everything is masked. The
  /// SwiftUI adapter has no host-only mode.
  enum Mode: String {
    case precise
    case wholeFrame
  }

  /// Why the frame was masked in full (with `wholeFrame`), or which
  /// fail-closed boxes a precise frame contains (informational).
  enum Reason: String, CaseIterable {
    case noWindowSize
    case unverifiedLayerAllowlist
    case walkExhausted
    case animating
    case representable
    case webView
    case renderer
    case unclassifiedLayer
  }

  let mode: Mode
  /// Unique, in `Reason.allCases` order.
  let reasons: [Reason]
}

extension MaskResult {
  /// A fail-closed box over at least this share of the window masks the
  /// frame in effect: the summary then says `wholeFrame`, with the box
  /// reasons, so the diagnostic matches the pixels.
  static let wholeFrameBoxFraction = 0.9

  /// The summary of this result: the fallback reason for a whole frame;
  /// `wholeFrame` with the box reasons when a box covers (nearly) the whole
  /// window; else `precise` with the kinds of fail-closed boxes it contains.
  var coverage: MaskCoverage {
    if let fallback = fallback {
      return MaskCoverage(mode: .wholeFrame, reasons: [MaskResult.reason(for: fallback)])
    }
    let present: [MaskCoverage.Reason: Bool] = [
      .representable: stats.representableBoxes > 0,
      .webView: stats.webViewBoxes > 0,
      .renderer: stats.rendererBoxes > 0,
      .unclassifiedLayer: stats.unclassifiedLayers > 0,
    ]
    let reasons = MaskCoverage.Reason.allCases.filter { present[$0] == true }
    let mode: MaskCoverage.Mode = stats.largestBoxFraction >= MaskResult.wholeFrameBoxFraction ? .wholeFrame : .precise
    return MaskCoverage(mode: mode, reasons: reasons)
  }

  private static func reason(for fallback: MaskFallback) -> MaskCoverage.Reason {
    switch fallback {
    case .noWindow: return .noWindowSize
    case .unverifiedLayerAllowlist: return .unverifiedLayerAllowlist
    case .walkLimitExceeded: return .walkExhausted
    case .animating: return .animating
    }
  }
}

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
  /// The summary of this result: the fallback reason for a whole frame,
  /// else the kinds of fail-closed boxes the precise mask contains.
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
    return MaskCoverage(mode: .precise, reasons: MaskCoverage.Reason.allCases.filter { present[$0] == true })
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

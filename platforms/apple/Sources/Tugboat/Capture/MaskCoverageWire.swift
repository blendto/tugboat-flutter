/// The SwiftUI adapter's `MaskCoverage` in the engine's `maskCoverage`
/// vocabulary (PR #96: modes `precise`, `wholeHost`, `wholeFrame`; 14
/// closed reason names). Every SwiftUI reason has the engine's name except
/// `renderer` (Metal, video, OpenGL and portal views masked as boxes),
/// which is the engine's `surfaceLayer`: content drawn outside the view
/// hierarchy's own layers, the same class Android reports for
/// `SurfaceView` (decisions log).
extension MaskCoverage {
  var wire: WireMaskCoverage {
    WireMaskCoverage(mode: mode.rawValue, reasons: reasons.map(MaskCoverage.wireName))
  }

  static func wireName(_ reason: Reason) -> String {
    switch reason {
    case .renderer: return "surfaceLayer"
    case .noWindowSize, .unverifiedLayerAllowlist, .walkExhausted, .animating, .representable, .webView,
      .unclassifiedLayer:
      return reason.rawValue
    }
  }
}

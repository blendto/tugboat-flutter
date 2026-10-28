/// The size of the captured window in points, read once in the capture's
/// draw turn: the capture boundary, the space of mask rectangles and
/// pointer facts, and the basis of the frame's pixel size.
struct CaptureGeometry: Equatable {
  /// Flutter `TugboatReplayConfig.capturePixelRatio` default: JPEG pixels
  /// per point before the engine's `scale`.
  static let capturePixelRatio = 0.75
  private static let minScale = 0.1

  let width: Double
  let height: Double

  /// Nil when the window has no size.
  init?(width: Double, height: Double) {
    guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
    self.width = width
    self.height = height
  }

  /// The boundary at the window's origin.
  var boundaryRect: BoundaryRect {
    BoundaryRect(x: 0, y: 0, width: width, height: height)
  }

  /// JPEG pixels per point for a request: `capturePixelRatio` times the
  /// engine's `scale`, bounded to [0.1, 1]. Below one pixel per point it
  /// never exceeds the window's own pixels.
  static func pixelsPerPoint(scale: Double) -> Double {
    let bounded = scale.isFinite ? min(max(scale, minScale), 1) : 1
    return capturePixelRatio * bounded
  }
}

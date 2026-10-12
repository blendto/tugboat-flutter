import Foundation

/// The size of the captured window in points, which is the capture
/// boundary and the space of mask rectangles and pointer facts.
struct CaptureGeometry: Equatable {
  /// Flutter `TugboatReplayConfig.capturePixelRatio` default: JPEG pixels
  /// per point before the engine's `scale`.
  static let capturePixelRatio = 0.75
  private static let minScale = 0.1
  private static let epsilon = 1e-6

  let width: Double
  let height: Double
  /// Physical pixels per point; the encoded size never exceeds the
  /// window's own pixels.
  let screenScale: Double

  /// Nil when the window has no size.
  init?(width: Double, height: Double, screenScale: Double) {
    guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
    self.width = width
    self.height = height
    self.screenScale = screenScale.isFinite && screenScale > 0 ? screenScale : 1
  }

  /// The boundary at the window's origin.
  var boundaryRect: BoundaryRect {
    BoundaryRect(x: 0, y: 0, width: width, height: height)
  }

  /// Encoded frame size: `capturePixelRatio` pixels per point times the
  /// engine's `scale`, at least one pixel and at most the window's pixels.
  func pixelSize(scale: Double) -> (width: Int, height: Int) {
    let bounded = scale.isFinite ? min(max(scale, CaptureGeometry.minScale), 1) : 1
    let ratio = CaptureGeometry.capturePixelRatio * bounded
    return (pixels(width, ratio), pixels(height, ratio))
  }

  /// Rounds up, ignoring float noise.
  private func pixels(_ points: Double, _ ratio: Double) -> Int {
    let most = max(1, (points * screenScale).rounded(.down))
    let wanted = (points * ratio - CaptureGeometry.epsilon).rounded(.up)
    return Int(min(max(wanted, 1), min(most, 8192)))
  }
}

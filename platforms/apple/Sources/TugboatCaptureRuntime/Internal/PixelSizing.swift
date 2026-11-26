import CoreGraphics
import Foundation

/// The bitmap size of one draw: the request's fixed `pixelWidth` x
/// `pixelHeight`, or, with `pixelsPerPoint`, the view's bounds read in the
/// draw turn times that ratio, so the size and the drawn layout come from
/// one reading.
struct PixelSizing {
  static let maxEdge = 8192
  static let maxPixels = 16_777_216
  private static let epsilon = 1e-6

  let fixedWidth: Int
  let fixedHeight: Int
  let pixelsPerPoint: Double

  init(_ request: CaptureRequest) {
    fixedWidth = request.pixelWidth
    fixedHeight = request.pixelHeight
    pixelsPerPoint = request.pixelsPerPoint
  }

  /// True when the size follows the bounds at draw time.
  var followsBounds: Bool {
    pixelsPerPoint.isFinite && pixelsPerPoint > 0
  }

  /// The size for `bounds`, or nil when it is empty or over the limits.
  func size(for bounds: CGSize) -> (width: Int, height: Int)? {
    guard followsBounds else {
      return PixelSizing.valid(fixedWidth, fixedHeight)
    }
    guard let width = scaled(Double(bounds.width)), let height = scaled(Double(bounds.height)) else {
      return nil
    }
    return PixelSizing.valid(width, height)
  }

  /// Rounds up, ignoring float noise (390 x 0.6 is 234, not 235).
  private func scaled(_ points: Double) -> Int? {
    let pixels = (points * pixelsPerPoint - PixelSizing.epsilon).rounded(.up)
    guard pixels.isFinite, pixels <= Double(PixelSizing.maxEdge) else { return nil }
    return max(1, Int(pixels))
  }

  static func valid(_ width: Int, _ height: Int) -> (width: Int, height: Int)? {
    guard width > 0, height > 0, width <= maxEdge, height <= maxEdge, width <= maxPixels / height else {
      return nil
    }
    return (width, height)
  }
}

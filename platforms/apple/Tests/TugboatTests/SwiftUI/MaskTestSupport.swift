#if canImport(UIKit)
import UIKit

@testable import Tugboat

extension MaskResult {
  /// The fraction of `frame` (window points) inside the mask, on a 10x10
  /// grid of sample points.
  func coverage(of frame: CGRect, in window: UIWindow) -> Double {
    let bounds = window.bounds
    let boxes = rects.map {
      CGRect(
        x: $0.x * Double(bounds.width), y: $0.y * Double(bounds.height),
        width: $0.width * Double(bounds.width), height: $0.height * Double(bounds.height)
      )
    }
    let steps = 10
    var inside = 0
    for i in 0..<steps {
      for j in 0..<steps {
        let point = CGPoint(
          x: frame.minX + frame.width * (CGFloat(i) + 0.5) / CGFloat(steps),
          y: frame.minY + frame.height * (CGFloat(j) + 0.5) / CGFloat(steps)
        )
        if boxes.contains(where: { $0.contains(point) }) { inside += 1 }
      }
    }
    return Double(inside) / Double(steps * steps)
  }
}

extension HostedWindow {
  /// Masks once nothing is animating (appear transitions, scroll indicator
  /// flashes), or the animating result after `timeout`.
  func settledMasks(allowlist: LayerAllowlist? = LayerAllowlist.forMajor(LayerAllowlist.runningMajor), timeout: TimeInterval = 4) -> MaskResult {
    var result = WindowMasks.compute(window, allowlist: allowlist)
    wait(timeout: timeout) {
      result = WindowMasks.compute(self.window, allowlist: allowlist)
      return result.fallback != .animating
    }
    return result
  }
}

enum TestImages {
  /// A small opaque bitmap, drawn by SwiftUI as an `ImageLayer`.
  static let swatch: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
    UIColor.systemPink.setFill()
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
  }
}
#endif

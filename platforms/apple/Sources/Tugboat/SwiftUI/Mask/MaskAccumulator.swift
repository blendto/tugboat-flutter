#if canImport(UIKit)
import UIKit

/// The state of one mask walk: rectangles in window coordinates, what was
/// found, and a node budget shared by the view and layer walks. When the
/// budget runs out the walk stops and the whole frame is masked.
struct MaskAccumulator {
  static let defaultBudget = 8000

  let window: UIWindow
  private(set) var rects: [CGRect] = []
  var stats = MaskStats()
  private var remaining: Int
  private(set) var exhausted = false

  init(window: UIWindow, budget: Int = MaskAccumulator.defaultBudget) {
    self.window = window
    self.remaining = budget
  }

  /// Takes one node from the budget; false once it is spent.
  mutating func spend() -> Bool {
    guard remaining > 0 else {
      exhausted = true
      return false
    }
    remaining -= 1
    return true
  }

  mutating func add(view: UIView) {
    add(view.convert(view.bounds, to: window))
  }

  mutating func add(layer: CALayer, padding: CGFloat = 0) {
    let frame = layer.convert(layer.bounds, to: window.layer)
    add(padding > 0 ? frame.insetBy(dx: -padding, dy: -padding) : frame)
  }

  private mutating func add(_ rect: CGRect) {
    guard !rect.isNull, !rect.isInfinite, rect.width > 0, rect.height > 0 else { return }
    rects.append(rect)
  }

  /// The result: normalized rectangles, or the whole frame when the budget
  /// ran out.
  func result() -> MaskResult {
    if exhausted {
      return .wholeFrame(.walkBudgetExceeded, stats: stats)
    }
    let bounds = window.bounds
    return MaskResult(rects: rects.compactMap { MaskRect($0, in: bounds) }, fallback: nil, stats: stats)
  }
}
#endif

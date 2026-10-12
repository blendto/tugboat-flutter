#if canImport(UIKit)
import UIKit

/// The state of one mask walk: rectangles in window coordinates, what was
/// found, a node budget shared by the view and layer walks, and the first
/// reason to mask the whole frame. Once a fallback is set the walk stops.
struct MaskAccumulator {
  static let defaultBudget = 8000

  let window: UIWindow
  private(set) var rects: [CGRect] = []
  var stats = MaskStats()
  private(set) var fallback: MaskFallback?
  private var remaining: Int

  init(window: UIWindow, budget: Int = MaskAccumulator.defaultBudget) {
    self.window = window
    self.remaining = budget
  }

  /// True once the whole frame will be masked: walking further is moot.
  var isDone: Bool {
    fallback != nil
  }

  /// Masks the whole frame for `reason`; the first reason is kept.
  mutating func fail(_ reason: MaskFallback) {
    if fallback == nil {
      fallback = reason
    }
  }

  /// Takes one node from the budget; false (and the whole frame masked)
  /// once it is spent.
  mutating func spend() -> Bool {
    guard !isDone else { return false }
    guard remaining > 0 else {
      fail(.walkLimitExceeded)
      return false
    }
    remaining -= 1
    return true
  }

  mutating func add(view: UIView) {
    add(view.convert(view.bounds, to: window))
  }

  /// Adds a fail-closed box and records how much of the window it covers.
  mutating func addBox(view: UIView) {
    let frame = view.convert(view.bounds, to: window)
    add(frame)
    let bounds = window.bounds
    let visible = frame.intersection(bounds)
    guard !visible.isNull, bounds.width > 0, bounds.height > 0 else { return }
    let fraction = Double((visible.width * visible.height) / (bounds.width * bounds.height))
    if fraction.isFinite, fraction > stats.largestBoxFraction {
      stats.largestBoxFraction = fraction
    }
  }

  mutating func add(layer: CALayer, padding: CGFloat = 0) {
    let frame = layer.convert(layer.bounds, to: window.layer)
    add(padding > 0 ? frame.insetBy(dx: -padding, dy: -padding) : frame)
  }

  private mutating func add(_ rect: CGRect) {
    guard !rect.isNull, !rect.isInfinite, rect.width > 0, rect.height > 0 else { return }
    rects.append(rect)
  }

  /// Normalized rectangles, or the whole frame with the fallback reason.
  func result() -> MaskResult {
    if let fallback = fallback {
      return .wholeFrame(fallback, stats: stats)
    }
    let bounds = window.bounds
    return MaskResult(rects: rects.compactMap { MaskRect($0, in: bounds) }, fallback: nil, stats: stats)
  }
}
#endif

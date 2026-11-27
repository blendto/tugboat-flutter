#if canImport(UIKit)
import UIKit

/// The control state a structure signature needs and the mask walk does
/// not see: for each visible `UIControl` its kind and selected /
/// highlighted / enabled state (and `isOn` for a `UISwitch`), and every
/// visible view with the accessibility `selected` trait, in walk order.
/// SwiftUI `Toggle`, `Picker` and tab bars are backed by such UIKit views.
/// Main thread only, inside the capture's draw turn; bounded.
enum StructureProbe {
  static let maxViews = 4000

  static func controls(in window: UIWindow) -> [Int64] {
    var out: [Int64] = []
    var stack: [UIView] = [window]
    var visited = 0
    while let view = stack.popLast(), visited < maxViews {
      visited += 1
      if view.isHidden || view.alpha <= 0 { continue }
      if let state = state(of: view, index: visited) {
        out.append(state)
      }
      stack.append(contentsOf: view.subviews.reversed())
    }
    return out
  }

  /// Nil for a view without control state. The walk index keeps two equal
  /// states at different places apart.
  private static func state(of view: UIView, index: Int) -> Int64? {
    let selectedTrait = view.accessibilityTraits.contains(.selected)
    guard let control = view as? UIControl else {
      return selectedTrait ? Int64(index) << 8 | 1 : nil
    }
    var bits: Int64 = 2
    if control.isSelected { bits |= 4 }
    if control.isHighlighted { bits |= 8 }
    if control.isEnabled { bits |= 16 }
    if (control as? UISwitch)?.isOn == true { bits |= 32 }
    if selectedTrait { bits |= 1 }
    return Int64(index) << 8 | bits
  }
}
#endif

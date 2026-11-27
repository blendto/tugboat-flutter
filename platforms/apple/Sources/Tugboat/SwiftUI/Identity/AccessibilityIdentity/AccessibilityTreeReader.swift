#if canImport(UIKit)
import UIKit

/// The last path segment of a tap refined by the accessibility tree
/// (ADR 0010): `AXIdentified#<k>`, or `AX<Role>#<k>` with the anchor `role`.
struct AccessibilityLeaf: Equatable {
  static let identifiedToken = "AXIdentified"

  let token: String
  let ordinal: Int
  let role: String?

  var segment: String {
    "\(token)#\(ordinal)"
  }
}

/// Finds the accessibility element at a tap (ADR 0010, "Reading").
///
/// - No full-tree walk: from the root, descend only into children whose
///   `accessibilityFrame` (screen coordinates, converted to window points)
///   contains the point, through `accessibilityElements` or
///   `accessibilityElementCount()` / `accessibilityElement(at:)`.
///   `accessibilityHitTest(_:)` returns nil without an assistive client, so
///   it is not used.
/// - The smallest `isAccessibilityElement` element containing the point
///   wins; on a tie, the deeper one. Hidden elements are skipped with their
///   children.
/// - Reads each visited element's frame, `isAccessibilityElement`,
///   identifier and traits, nothing else. The identifier is only tested for
///   being non-empty: its value never leaves here. Labels and values are
///   never read.
/// - Every child whose frame is read counts against `budget`; over it, or
///   with nothing found, the answer is nil (the tap keeps today's result).
///
/// Ordinals: an element with an identifier is `AXIdentified#<k>`, `k` the
/// number of identified elements before it on the descent (at each level,
/// the siblings before the container it went into, then its own siblings).
/// Any other element is `AX<Role>#<k>`, `k` its ordinal among its siblings
/// without an identifier and with the same role (`AccessibilityRole`).
///
/// Main thread only.
struct AccessibilityTreeReader {
  static let visitBudget = 256
  static let maxDepth = 32

  var budget = AccessibilityTreeReader.visitBudget

  /// One level of the descent: the children of a container and which of
  /// them it went into.
  private struct Step {
    let siblings: [NSObject]
    let index: Int
  }

  private struct Candidate {
    let area: CGFloat
    let chain: [Step]
  }

  private struct Walk {
    let point: CGPoint
    let toWindow: (CGRect) -> CGRect
    var visits = 0
    var best: Candidate?
  }

  /// The leaf at `point` (window points) under `root`; `toWindow` converts
  /// an `accessibilityFrame` to window points.
  func leaf(at point: CGPoint, under root: NSObject, toWindow: @escaping (CGRect) -> CGRect) -> AccessibilityLeaf? {
    var walk = Walk(point: point, toWindow: toWindow)
    guard descend(root, chain: [], walk: &walk), let best = walk.best else { return nil }
    return AccessibilityTreeReader.leaf(of: best.chain)
  }

  /// False when the budget ran out.
  private func descend(_ container: NSObject, chain: [Step], walk: inout Walk) -> Bool {
    guard chain.count < AccessibilityTreeReader.maxDepth else { return true }
    let children = AccessibilityTreeReader.children(of: container, limit: budget - walk.visits + 1)
    for (index, child) in children.enumerated() {
      walk.visits += 1
      guard walk.visits <= budget else { return false }
      guard !AccessibilityTreeReader.isHidden(child) else { continue }
      let frame = walk.toWindow(child.accessibilityFrame)
      guard !frame.isNull, !frame.isEmpty, frame.contains(walk.point) else { continue }
      let path = chain + [Step(siblings: children, index: index)]
      let area = frame.width * frame.height
      if child.isAccessibilityElement, AccessibilityTreeReader.beats(area: area, depth: path.count, walk.best) {
        walk.best = Candidate(area: area, chain: path)
      }
      guard descend(child, chain: path, walk: &walk) else { return false }
    }
    return true
  }

  /// Smaller wins; on a tie, deeper wins.
  private static func beats(area: CGFloat, depth: Int, _ best: Candidate?) -> Bool {
    guard let best = best else { return true }
    return area < best.area || (area == best.area && depth > best.chain.count)
  }

  private static func leaf(of chain: [Step]) -> AccessibilityLeaf? {
    guard let last = chain.last else { return nil }
    let element = last.siblings[last.index]
    if isIdentified(element) {
      let before = chain.reduce(0) { count, step in
        count + step.siblings[..<step.index].filter { $0.isAccessibilityElement && isIdentified($0) }.count
      }
      return AccessibilityLeaf(token: AccessibilityLeaf.identifiedToken, ordinal: before, role: nil)
    }
    let role = AccessibilityRole.role(of: element.accessibilityTraits)
    let ordinal = last.siblings[..<last.index].filter { sibling in
      sibling.isAccessibilityElement && !isIdentified(sibling) && AccessibilityRole.role(of: sibling.accessibilityTraits) == role
    }.count
    return AccessibilityLeaf(token: AccessibilityRole.token(of: role), ordinal: ordinal, role: role)
  }

  /// At most `limit` accessibility children of `container`.
  private static func children(of container: NSObject, limit: Int) -> [NSObject] {
    guard limit > 0 else { return [] }
    if let elements = container.accessibilityElements {
      return elements.prefix(limit).compactMap { $0 as? NSObject }
    }
    let count = container.accessibilityElementCount()
    guard count > 0, count != NSNotFound else { return [] }
    return (0..<min(count, limit)).compactMap { container.accessibilityElement(at: $0) as? NSObject }
  }

  private static func isHidden(_ element: NSObject) -> Bool {
    if element.accessibilityElementsHidden {
      return true
    }
    guard let view = element as? UIView else { return false }
    return view.isHidden || view.alpha <= 0.01
  }

  private static let identifierGetter = #selector(getter: UIAccessibilityIdentification.accessibilityIdentifier)

  /// Whether `element` has a non-empty `accessibilityIdentifier`. The value
  /// is not kept.
  private static func isIdentified(_ element: NSObject) -> Bool {
    if let identification = element as? UIAccessibilityIdentification {
      return !(identification.accessibilityIdentifier ?? "").isEmpty
    }
    guard element.responds(to: identifierGetter) else { return false }
    let value = element.perform(identifierGetter)?.takeUnretainedValue() as? String
    return !(value ?? "").isEmpty
  }
}

/// Accessibility traits as the anchor `role` names other adapters already
/// use. Checked in this order, so a toggle that is also a button is
/// `switch`. Traits that map to no role give `AXElement` and no `role`.
enum AccessibilityRole {
  static let elementToken = "AXElement"

  static func role(of traits: UIAccessibilityTraits) -> String? {
    if #available(iOS 17.0, *), traits.contains(.toggleButton) { return "switch" }
    if traits.contains(.button) { return "button" }
    if traits.contains(.link) { return "link" }
    if traits.contains(.searchField) { return "textField" }
    if traits.contains(.adjustable) { return "adjustable" }
    if traits.contains(.image) { return "image" }
    if traits.contains(.header) { return "header" }
    return nil
  }

  /// `AX` and the role with its first letter capitalized (`AXButton`,
  /// `AXTextField`), or `AXElement`.
  static func token(of role: String?) -> String {
    guard let role = role, let first = role.first else { return elementToken }
    return "AX" + first.uppercased() + role.dropFirst()
  }
}
#endif

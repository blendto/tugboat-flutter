import UIKit

/// Answers one question for the SwiftUI adapter design (native SDK note
/// section 6.3): without VoiceOver, can in-process code read the SwiftUI
/// accessibility tree, and which UIKit views carry text?
///
/// Every output line starts with `A11YPROBE` so it can be grepped from the
/// simulator console.
@MainActor
enum Probe {
  struct Result {
    let summary: String
    let full: String
  }

  private struct Leaf {
    let path: String
    let frame: CGRect
    let identifier: String?
  }

  private struct Stats {
    var views = 0
    var hostingViews = 0
    var uikitTextViews: [String] = []
    var listViews: [String] = []
    var leafElements = 0
    var labeledLeaves = 0
    var identifiers: Set<String> = []
    var leaves: [Leaf] = []
  }

  private static let maxDepth = 60
  private static let maxNodes = 3000

  static func run(label: String) -> Result {
    var lines: [String] = []
    guard let window = keyWindow() else {
      let line = "A11YPROBE \(label) no window"
      return Result(summary: line, full: line)
    }
    lines.append(
      "A11YPROBE \(label) iOS=\(UIDevice.current.systemVersion) "
        + "voiceOver=\(UIAccessibility.isVoiceOverRunning) "
        + "switchControl=\(UIAccessibility.isSwitchControlRunning)"
    )

    var stats = Stats()
    lines.append("A11YPROBE \(label) -- view hierarchy --")
    walkViews(window, in: window, depth: 0, label: label, lines: &lines, stats: &stats)

    lines.append("A11YPROBE \(label) -- accessibility tree --")
    var visited = Set<ObjectIdentifier>()
    walkElement(window, path: "window", depth: 0, label: label, lines: &lines, stats: &stats, visited: &visited)

    lines.append(contentsOf: hitTestLines(label: label, stats: stats))

    let wanted = ["probe.button", "probe.field", "probe.list"]
    let found = wanted.filter { stats.identifiers.contains($0) }
    let summary =
      "\(label): leaves=\(stats.leafElements) labeled=\(stats.labeledLeaves) "
      + "ids=\(found.count)/\(wanted.count) hosting=\(stats.hostingViews) "
      + "uikitText=\(stats.uikitTextViews.count) lists=\(stats.listViews.joined(separator: ","))"
    lines.append("A11YPROBE \(label) SUMMARY \(summary)")
    lines.append(
      "A11YPROBE \(label) VERDICT treePopulatedWithoutVoiceOver=\(stats.labeledLeaves >= 4) "
        + "identifiersVisible=\(found == wanted)"
    )
    return Result(summary: summary, full: lines.joined(separator: "\n"))
  }

  private static func keyWindow() -> UIWindow? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    return windows.first(where: { $0.isKeyWindow }) ?? windows.first
  }

  // MARK: UIKit view hierarchy

  private static func walkViews(
    _ view: UIView,
    in window: UIWindow,
    depth: Int,
    label: String,
    lines: inout [String],
    stats: inout Stats
  ) {
    guard depth <= maxDepth, stats.views < maxNodes else { return }
    stats.views += 1
    let type = String(describing: Swift.type(of: view))
    if type.contains("Hosting") { stats.hostingViews += 1 }

    var notes: [String] = []
    if let text = textCarried(by: view) {
      stats.uikitTextViews.append(type)
      notes.append("text=\(quoted(text))")
    }
    if view is UICollectionView || view is UITableView {
      stats.listViews.append(type)
    }
    if let indexPath = indexPath(of: view) {
      notes.append("indexPath=\(indexPath.section).\(indexPath.row)")
    }
    let frame = view.convert(view.bounds, to: window)
    lines.append(
      "A11YPROBE \(label) V \(String(repeating: " ", count: depth))\(type) "
        + "frame=\(rect(frame)) isElement=\(view.isAccessibilityElement) "
        + "count=\(view.accessibilityElementCount()) "
        + "elements=\(view.accessibilityElements.map { String($0.count) } ?? "nil") "
        + "id=\(quoted(view.accessibilityIdentifier)) label=\(quoted(view.accessibilityLabel)) "
        + notes.joined(separator: " ")
    )
    for subview in view.subviews {
      walkViews(subview, in: window, depth: depth + 1, label: label, lines: &lines, stats: &stats)
    }
  }

  private static func textCarried(by view: UIView) -> String? {
    if let label = view as? UILabel { return label.text ?? "" }
    if let field = view as? UITextField { return field.text ?? field.placeholder ?? "" }
    if let textView = view as? UITextView { return textView.text ?? "" }
    return nil
  }

  private static func indexPath(of view: UIView) -> IndexPath? {
    var ancestor = view.superview
    while let current = ancestor {
      if let cell = view as? UICollectionViewCell, let collection = current as? UICollectionView {
        return collection.indexPath(for: cell)
      }
      if let cell = view as? UITableViewCell, let table = current as? UITableView {
        return table.indexPath(for: cell)
      }
      ancestor = current.superview
    }
    return nil
  }

  // MARK: Accessibility tree (VoiceOver-style traversal)

  private static func walkElement(
    _ element: NSObject,
    path: String,
    depth: Int,
    label: String,
    lines: inout [String],
    stats: inout Stats,
    visited: inout Set<ObjectIdentifier>
  ) {
    guard depth <= maxDepth, visited.count < maxNodes else { return }
    guard visited.insert(ObjectIdentifier(element)).inserted else { return }
    if let view = element as? UIView, view.isHidden || view.alpha == 0 { return }

    let children = accessibilityChildren(of: element)
    let isLeaf = element.isAccessibilityElement
    if let identifier = element.accessibilityIdentifierIfAny, !identifier.isEmpty {
      stats.identifiers.insert(identifier)
    }
    if isLeaf {
      stats.leafElements += 1
      if let text = element.accessibilityLabel, !text.isEmpty { stats.labeledLeaves += 1 }
      stats.leaves.append(
        Leaf(path: path, frame: element.accessibilityFrame, identifier: element.accessibilityIdentifierIfAny)
      )
      lines.append(
        "A11YPROBE \(label) E \(String(repeating: " ", count: depth))"
          + "\(String(describing: Swift.type(of: element))) "
          + "traits=\(traitNames(element.accessibilityTraits)) "
          + "label=\(quoted(element.accessibilityLabel)) value=\(quoted(element.accessibilityValue)) "
          + "id=\(quoted(element.accessibilityIdentifierIfAny)) frame=\(rect(element.accessibilityFrame))"
      )
    }
    for (index, child) in children.enumerated() {
      walkElement(
        child, path: "\(path)/\(index)", depth: depth + 1, label: label,
        lines: &lines, stats: &stats, visited: &visited)
    }
  }

  /// Children the way VoiceOver finds them: explicit `accessibilityElements`,
  /// then the indexed container API, then (for views) subviews.
  private static func accessibilityChildren(of element: NSObject) -> [NSObject] {
    if let explicit = element.accessibilityElements as? [NSObject], !explicit.isEmpty {
      return explicit
    }
    let count = element.accessibilityElementCount()
    if count > 0, count != NSNotFound {
      return (0..<count).compactMap { element.accessibilityElement(at: $0) as? NSObject }
    }
    if let view = element as? UIView, !view.isAccessibilityElement {
      return view.subviews
    }
    return []
  }

  // MARK: Hit testing

  /// For the centre of each identified leaf, which leaf would a frame-based
  /// hit test pick? Checks that tap targets can come from this tree.
  private static func hitTestLines(label: String, stats: Stats) -> [String] {
    stats.leaves.compactMap { leaf -> String? in
      guard let identifier = leaf.identifier, identifier.hasPrefix("probe.") else { return nil }
      let point = CGPoint(x: leaf.frame.midX, y: leaf.frame.midY)
      let hit = stats.leaves
        .filter { $0.frame.contains(point) }
        .min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
      return "A11YPROBE \(label) HIT \(identifier) at \(Int(point.x)),\(Int(point.y)) -> "
        + "\(hit?.identifier ?? "nil") (\(hit?.path ?? "none"))"
    }
  }

  // MARK: Formatting

  private static func traitNames(_ traits: UIAccessibilityTraits) -> String {
    let named: [(UIAccessibilityTraits, String)] = [
      (.button, "button"), (.link, "link"), (.header, "header"), (.staticText, "staticText"),
      (.image, "image"), (.searchField, "searchField"), (.adjustable, "adjustable"),
      (.selected, "selected"), (.notEnabled, "notEnabled"), (.keyboardKey, "keyboardKey"),
      (.updatesFrequently, "updatesFrequently"), (.tabBar, "tabBar"),
    ]
    let names = named.filter { traits.contains($0.0) }.map { $0.1 }
    return names.isEmpty ? "[]" : "[\(names.joined(separator: ","))]"
  }

  private static func rect(_ frame: CGRect) -> String {
    "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height))"
  }

  private static func quoted(_ text: String?) -> String {
    guard let text = text else { return "nil" }
    return "\"\(text.prefix(40))\""
  }
}

private extension NSObject {
  /// `accessibilityIdentifier` is declared on `UIAccessibilityIdentification`,
  /// which UIView and UIAccessibilityElement adopt; SwiftUI's element class
  /// may not, so read it defensively.
  var accessibilityIdentifierIfAny: String? {
    (self as? UIAccessibilityIdentification)?.accessibilityIdentifier
  }
}

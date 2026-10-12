#if canImport(UIKit)
import UIKit

/// A target's structural path within its route root, and the list index
/// path it sits in, if any.
struct CanonicalPath: Equatable {
  let value: String
  let indexPath: IndexPath?
}

/// Builds canonical paths for SwiftUI targets (native SDK note 6, 6.3).
///
/// - Segments come from the UIKit views between the route root and the
///   target that have a `TargetRole`: nested hosting views (`Host`),
///   scroll views (`Scrollable`), representable hosts (`Representable`),
///   text inputs (`TextField`). Everything else collapses.
/// - A segment is `Token#<ordinal>`. Ordinals count same-token siblings
///   after filtering: the role views and list cells whose nearest segment
///   ancestor is the same, in subview order. Hidden, transparent and
///   zero-size views are skipped with their subtrees.
/// - A list cell adds `[item:<section>.<row>]` from its index path and
///   scopes the ordinals of everything inside it; a cell that is itself the
///   target adds `Cell#0` after it.
/// - SwiftUI drawing (text, images, shapes) has no UIKit view, so it never
///   appears in a path; a tap on it resolves to the nearest role view.
///
/// The route root itself is not part of the path; an empty path is
/// `Root#0`.
enum CanonicalPathBuilder {
  static let rootSegment = "Root#0"
  private static let maxDepth = 128

  static func build(root: UIView, target: UIView) -> CanonicalPath? {
    guard let chain = chainBelow(root: root, target: target) else { return nil }
    var segments: [String] = []
    var scope = root
    var indexPath: IndexPath?
    var insideHosting = ViewKind.of(root, insideHosting: false) == .hosting
    for view in chain {
      if let item = itemIndexPath(of: view) {
        segments.append("[item:\(item.section).\(item.row)]")
        indexPath = item
        scope = view
        if view === target {
          segments.append(TargetRole.cell.token + "#0")
        }
      } else if let role = TargetRole.of(view, insideHosting: insideHosting) {
        segments.append(role.token + "#\(ordinal(of: view, token: role.token, in: scope, insideHosting: insideHosting))")
        scope = view
      }
      insideHosting = insideHosting || ViewKind.of(view, insideHosting: insideHosting) == .hosting
    }
    let value = segments.isEmpty ? rootSegment : segments.joined(separator: "/")
    return CanonicalPath(value: value, indexPath: indexPath)
  }

  /// The index path of `view` when it is a cell of a list.
  static func itemIndexPath(of view: UIView) -> IndexPath? {
    if let cell = view as? UICollectionViewCell {
      return enclosing(UICollectionView.self, of: cell)?.indexPath(for: cell)
    }
    if let cell = view as? UITableViewCell {
      return enclosing(UITableView.self, of: cell)?.indexPath(for: cell)
    }
    return nil
  }

  /// The nearest `List` ancestor of a cell: its superview, or a wrapper
  /// view or two above it (`UITableViewWrapperView`).
  private static func enclosing<List: UIView>(_ type: List.Type, of cell: UIView) -> List? {
    var ancestor = cell.superview
    for _ in 0..<3 {
      guard let current = ancestor else { return nil }
      if let list = current as? List {
        return list
      }
      ancestor = current.superview
    }
    return nil
  }

  /// Ancestors strictly below `root` down to `target`, top first.
  private static func chainBelow(root: UIView, target: UIView) -> [UIView]? {
    var chain: [UIView] = []
    var current: UIView = target
    while current !== root {
      guard chain.count < maxDepth, let parent = current.superview else { return nil }
      chain.append(current)
      current = parent
    }
    return chain.reversed()
  }

  private static func ordinal(of view: UIView, token: String, in scope: UIView, insideHosting: Bool) -> Int {
    var ordinal = 0
    for sibling in segmentChildren(of: scope, insideHosting: insideHosting) {
      if sibling.view === view { return ordinal }
      if sibling.token == token { ordinal += 1 }
    }
    return ordinal
  }

  /// The role views and list cells whose nearest segment ancestor is
  /// `scope`, in subview order, with their tokens (nil for list cells).
  private static func segmentChildren(of scope: UIView, insideHosting: Bool) -> [(view: UIView, token: String?)] {
    var out: [(view: UIView, token: String?)] = []
    collect(scope, insideHosting: insideHosting || ViewKind.of(scope, insideHosting: insideHosting) == .hosting, depth: 0, into: &out)
    return out
  }

  private static func collect(_ parent: UIView, insideHosting: Bool, depth: Int, into out: inout [(view: UIView, token: String?)]) {
    guard depth < maxDepth else { return }
    for child in parent.subviews where !ViewKind.isExcluded(child) {
      if itemIndexPath(of: child) != nil {
        out.append((child, nil))
      } else if let role = TargetRole.of(child, insideHosting: insideHosting) {
        out.append((child, role.token))
      } else {
        collect(child, insideHosting: insideHosting, depth: depth + 1, into: &out)
      }
    }
  }
}
#endif

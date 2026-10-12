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
///   target whose kind has a path token: nested hosting views (`Host`),
///   scroll views (`Scrollable`), representables (`Representable`), text
///   inputs (`TextField`). Everything else collapses, including SwiftUI's
///   own platform-view hosts.
/// - A segment is `Token#<ordinal>`. Ordinals count same-token siblings
///   after filtering: the token views and list cells whose nearest segment
///   ancestor is the same, in subview order. Hidden, transparent, zero-size
///   and SDK-owned views are skipped with their subtrees.
/// - A list cell adds `[item:<section>.<row>]` from its index path and
///   scopes the ordinals of everything inside it; a cell that is itself the
///   target adds `Cell#0` after it.
/// - SwiftUI drawing (text, images, shapes) has no UIKit view, so it never
///   appears in a path.
///
/// The route root itself is not part of the path; an empty path is
/// `Root#0`.
enum CanonicalPathBuilder {
  static let rootSegment = "Root#0"

  /// A token view or list cell below a scope, with its token (nil for cells).
  private typealias Segment = (view: UIView, token: String?)

  static func build(root: UIView, target: UIView) -> CanonicalPath? {
    guard let lineage = ViewTree.lineage(from: root, to: target), var scope = lineage.first else { return nil }
    var segments: [String] = []
    var indexPath: IndexPath?
    for node in lineage.dropFirst() {
      if let item = itemIndexPath(of: node.view) {
        segments.append("[item:\(item.section).\(item.row)]")
        indexPath = item
        scope = node
        if node.view === target {
          segments.append("Cell#0")
        }
      } else if let token = node.kind.token {
        segments.append(token + "#\(ordinal(of: node.view, token: token, in: scope))")
        scope = node
      }
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

  private static func ordinal(of view: UIView, token: String, in scope: ViewNode) -> Int {
    var ordinal = 0
    var segments: [Segment] = []
    collect(below: scope, depth: 0, into: &segments)
    for segment in segments {
      if segment.view === view { return ordinal }
      if segment.token == token { ordinal += 1 }
    }
    return ordinal
  }

  /// The token views and list cells whose nearest segment ancestor is
  /// `parent`, in subview order.
  private static func collect(below parent: ViewNode, depth: Int, into out: inout [Segment]) {
    guard depth < ViewTree.maxDepth else { return }
    for child in ViewTree.children(of: parent) where !ViewTree.isExcludedFromIdentity(child) {
      if itemIndexPath(of: child.view) != nil {
        out.append((child.view, nil))
      } else if let token = child.kind.token {
        out.append((child.view, token))
      } else {
        collect(below: child, depth: depth + 1, into: &out)
      }
    }
  }
}
#endif

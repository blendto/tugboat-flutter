#if canImport(UIKit)
import UIKit

/// A view with its kind and whether a hosting view is above it.
struct ViewNode {
  let view: UIView
  let kind: ViewKind
  let insideHosting: Bool

  init(_ view: UIView, insideHosting: Bool) {
    self.view = view
    self.kind = ViewKind.of(view, insideHosting: insideHosting)
    self.insideHosting = insideHosting
  }

  /// Whether this node's subviews are inside a hosting view.
  var childrenInsideHosting: Bool {
    insideHosting || kind == .hosting
  }
}

/// The one way the adapter walks UIKit views: every walk gets each view's
/// `ViewKind` from here, so "is a hosting view above it" is computed once
/// per walk rather than by each caller.
enum ViewTree {
  static let maxDepth = 128

  /// The node of `view`, looking up its ancestors for a hosting view.
  static func node(_ view: UIView) -> ViewNode {
    var ancestor = view.superview
    var depth = 0
    while let current = ancestor, depth < maxDepth {
      if ViewKind.of(current, insideHosting: false) == .hosting {
        return ViewNode(view, insideHosting: true)
      }
      ancestor = current.superview
      depth += 1
    }
    return ViewNode(view, insideHosting: false)
  }

  static func children(of node: ViewNode) -> [ViewNode] {
    let inside = node.childrenInsideHosting
    return node.view.subviews.map { ViewNode($0, insideHosting: inside) }
  }

  /// The nodes from `top` down to `view`, both included, or nil when `view`
  /// is not `top` or below it.
  static func lineage(from top: UIView, to view: UIView) -> [ViewNode]? {
    var views: [UIView] = [view]
    var current = view
    while current !== top {
      guard views.count < maxDepth, let parent = current.superview else { return nil }
      views.append(parent)
      current = parent
    }
    var nodes: [ViewNode] = []
    var inside = node(top).insideHosting
    for view in views.reversed() {
      let node = ViewNode(view, insideHosting: inside)
      nodes.append(node)
      inside = node.childrenInsideHosting
    }
    return nodes
  }

  /// Left out of identity: hidden, transparent, zero-size, or SDK-owned.
  static func isExcludedFromIdentity(_ node: ViewNode) -> Bool {
    let view = node.view
    return node.kind == .sdkOwned || view.isHidden || view.alpha <= 0.01
      || view.bounds.width <= 0 || view.bounds.height <= 0
  }

  /// Left out of masks: hidden or transparent, or zero-size and clipping
  /// (a zero-size view that does not clip can still show its subviews).
  static func isInvisibleForMasks(_ view: UIView) -> Bool {
    if view.isHidden || view.alpha <= 0.01 {
      return true
    }
    let empty = view.bounds.width <= 0 || view.bounds.height <= 0
    return empty && view.clipsToBounds
  }
}
#endif

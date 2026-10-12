#if canImport(UIKit)
import UIKit

/// Resolves target anchors against the live window (native SDK note 6, 6.3).
///
/// - **Tap target.** A `.tugboatTag` at the point wins: the smallest tagged
///   frame in the hit view's window and hosting root. Otherwise UIKit
///   hit-testing at the point, then the nearest ancestor that is a target
///   kind: text input, list cell, scroll view, representable. A hit on bare
///   SwiftUI drawing with none of those is `no_actionable_candidate`.
/// - **Tagged anchors** describe the tag, not the UIKit view around it:
///   `widgetType` is the neutral `SwiftUIView`, and `role`, `actions` and
///   `enabled` are omitted (a tagged button inside a scroll view is not
///   `scrollable`).
/// - **Fingerprint.** Hash of `routeKey` + the canonical path of the view
///   under the point. A tag adds `tagFingerprint` (`routeKey` + `tag`) and
///   leaves the structural fingerprint unchanged.
/// - **Confidence.** The floor of the route's and the path's. The path is
///   `high` with a tag, `medium` inside a list cell (index path), `low`
///   otherwise.
///
/// Main thread only.
final class AnchorResolver {
  static let taggedWidgetType = "SwiftUIView"

  private let tags: TagRegistry
  private let screens: ScreenTracker

  init(tags: TagRegistry, screens: ScreenTracker) {
    self.tags = tags
    self.screens = screens
  }

  /// Tap evidence for a touch whose down was at `point` (window points).
  func tapEvidence(in window: UIWindow, at point: CGPoint) -> TapEvidence {
    let hit = window.hitTest(point, with: nil)
    let lineage = hit.flatMap { ViewTree.lineage(from: window, to: $0) } ?? []
    let root = lineage.first { $0.kind == .hosting }?.view ?? window
    if let tagged = tags.marker(at: point, in: window, root: root) {
      let base = AnchorResolver.nearestTarget(in: lineage) ?? lineage.last { $0.kind == .hosting }?.view ?? hit ?? window
      return evidence(anchor(for: base, in: window, tag: tagged.tugboatTag))
    }
    guard hit != nil else { return .failed(.noTargetAtPoint) }
    guard let target = AnchorResolver.nearestTarget(in: lineage) else { return .failed(.noActionableCandidate) }
    return evidence(anchor(for: target, in: window, tag: nil))
  }

  /// The anchor of `view` (a scrollable at scroll start), or nil when it is
  /// not in `window`.
  func anchor(for view: UIView, in window: UIWindow) -> TargetAnchor? {
    anchor(for: view, in: window, tag: nil)
  }

  private func evidence(_ anchor: TargetAnchor?) -> TapEvidence {
    guard let anchor = anchor else { return .failed(.resolutionError) }
    return .anchor(anchor)
  }

  private func anchor(for view: UIView, in window: UIWindow, tag: String?) -> TargetAnchor? {
    guard view === window || view.isDescendant(of: window) else { return nil }
    screens.settle()
    let route = RouteKey.resolve(for: view, in: window, screen: screens.top)
    guard let path = CanonicalPathBuilder.build(root: route.root, target: view) else { return nil }
    let pathConfidence: Confidence = tag != nil ? .high : (path.indexPath != nil ? .medium : .low)
    let kind = ViewTree.node(view).kind
    let structural = IdentityHash.fingerprint([(key: "routeKey", value: route.value), (key: "path", value: path.value)])
    return TargetAnchor(
      widgetType: tag == nil ? kind.widgetType(of: view) : AnchorResolver.taggedWidgetType,
      role: tag == nil ? kind.anchorRole : nil,
      fingerprint: structural,
      confidence: Confidence.floor(route.confidence, pathConfidence),
      tagFingerprint: tag.map { IdentityHash.fingerprint([(key: "routeKey", value: route.value), (key: "tag", value: $0)]) },
      routeKey: route.value,
      tag: tag,
      canonicalPath: path.value,
      relativePosition: AnchorResolver.relativePosition(of: view, in: window),
      enabled: tag == nil && kind.isTarget ? ViewKind.isEnabled(view) : nil,
      actions: tag == nil ? kind.actions(of: view) : []
    )
  }

  /// The deepest node of `lineage` (window first) that is a list cell or a
  /// target kind.
  static func nearestTarget(in lineage: [ViewNode]) -> UIView? {
    lineage.dropFirst().last { node in
      CanonicalPathBuilder.itemIndexPath(of: node.view) != nil || node.kind.isTarget
    }?.view
  }

  /// Flutter's `_relativePosition`: the target centre's height in the window.
  private static func relativePosition(of view: UIView, in window: UIWindow) -> String? {
    let height = window.bounds.height
    guard height > 0 else { return nil }
    let frame = view.convert(view.bounds, to: window)
    let centre = frame.midY / height
    guard centre.isFinite else { return nil }
    if centre < 0.33 { return "top" }
    if centre > 0.66 { return "bottom" }
    return "center"
  }
}
#endif

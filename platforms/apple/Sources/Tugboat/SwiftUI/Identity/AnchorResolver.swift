#if canImport(UIKit)
import UIKit

/// Resolves target anchors against the live window (native SDK note 6, 6.3).
///
/// - **Tap target.** A `.tugboatTag` frame at the point wins (the smallest
///   containing one). Otherwise UIKit hit-testing at the point, then the
///   nearest ancestor with a target role: text input, list cell, scroll
///   view, representable host. A hit on bare SwiftUI drawing with none of
///   those is `no_actionable_candidate`.
/// - **Fingerprint.** Hash of `routeKey` + the canonical path. A tag gives
///   `tagFingerprint` (`routeKey` + `tag`) and leaves the structural
///   fingerprint unchanged.
/// - **Confidence.** The floor of the route's and the path's. The path is
///   `high` with a tag, `medium` inside a list cell (index path), `low`
///   otherwise.
///
/// Main thread only.
final class AnchorResolver {
  private let tags: TagRegistry
  private let screens: ScreenTracker

  init(tags: TagRegistry, screens: ScreenTracker) {
    self.tags = tags
    self.screens = screens
  }

  /// Tap evidence for a touch whose down was at `point` (window points).
  func tapEvidence(in window: UIWindow, at point: CGPoint) -> TapEvidence {
    let hit = window.hitTest(point, with: nil)
    let screen = screens.top
    let tagged = tags.entry(at: AnchorResolver.globalPoint(point, hit: hit, window: window), screen: screen?.instanceId)
    let target = hit.flatMap { AnchorResolver.nearestTarget(from: $0, stop: window) }
    if let tagged = tagged {
      let base = target ?? hit.flatMap { AnchorResolver.innermostHosting(from: $0, stop: window) } ?? hit ?? window
      return evidence(anchor(for: base, in: window, screen: screen, tag: tagged.tag))
    }
    guard hit != nil else { return .failed(.noTargetAtPoint) }
    guard let resolved = target else { return .failed(.noActionableCandidate) }
    return evidence(anchor(for: resolved, in: window, screen: screen, tag: nil))
  }

  /// The anchor of `view` (a scrollable at scroll start), or nil when it is
  /// not in `window`.
  func anchor(for view: UIView, in window: UIWindow) -> TargetAnchor? {
    anchor(for: view, in: window, screen: screens.top, tag: nil)
  }

  private func evidence(_ anchor: TargetAnchor?) -> TapEvidence {
    anchor.map { .anchor($0) } ?? .failed(.resolutionError)
  }

  private func anchor(for view: UIView, in window: UIWindow, screen: RouteEntry?, tag: String?) -> TargetAnchor? {
    guard view === window || view.isDescendant(of: window) else { return nil }
    let route = RouteKey.resolve(for: view, in: window, screen: screen)
    guard let path = CanonicalPathBuilder.build(root: route.root, target: view) else { return nil }
    let role = TargetRole.of(view, insideHosting: AnchorResolver.innermostHosting(from: view, stop: window) != nil)
    let pathConfidence: Confidence = tag != nil ? .high : (path.indexPath != nil ? .medium : .low)
    return TargetAnchor(
      widgetType: role?.widgetType(of: view) ?? "UIView",
      role: role?.anchorRole,
      fingerprint: IdentityHash.fingerprint([(key: "routeKey", value: route.value), (key: "path", value: path.value)]),
      confidence: Confidence.floor(route.confidence, pathConfidence),
      tagFingerprint: tag.map { IdentityHash.fingerprint([(key: "routeKey", value: route.value), (key: "tag", value: $0)]) },
      routeKey: route.value,
      tag: tag,
      canonicalPath: path.value,
      relativePosition: AnchorResolver.relativePosition(of: view, in: window),
      enabled: role == nil ? nil : TargetRole.isEnabled(view),
      actions: role?.actions(of: view) ?? []
    )
  }

  /// The nearest view from `start` up to `stop` with a target role.
  static func nearestTarget(from start: UIView, stop: UIView) -> UIView? {
    var chain: [UIView] = []
    var current: UIView? = start
    while let view = current, chain.count < 128 {
      chain.append(view)
      if view === stop { break }
      current = view.superview
    }
    // Whether a hosting view is above each view decides app-defined views.
    var hostingAbove = Array(repeating: false, count: chain.count)
    var seen = false
    for index in chain.indices.reversed() {
      hostingAbove[index] = seen
      seen = seen || ViewKind.of(chain[index], insideHosting: seen) == .hosting
    }
    for (index, view) in chain.enumerated() where view !== stop {
      if CanonicalPathBuilder.itemIndexPath(of: view) != nil {
        return view
      }
      if let role = TargetRole.of(view, insideHosting: hostingAbove[index]), role.isTarget {
        return view
      }
    }
    return nil
  }

  /// The innermost hosting view at or above `start`.
  static func innermostHosting(from start: UIView, stop: UIView) -> UIView? {
    hostingViews(from: start, stop: stop).first
  }

  /// `point` in SwiftUI's `.global` space for the hierarchy that was hit:
  /// the outermost hosting view above the hit view, else the window.
  static func globalPoint(_ point: CGPoint, hit: UIView?, window: UIWindow) -> CGPoint {
    guard let hit = hit, let root = hostingViews(from: hit, stop: window).last else { return point }
    return root.convert(point, from: window)
  }

  private static func hostingViews(from start: UIView, stop: UIView) -> [UIView] {
    var out: [UIView] = []
    var current: UIView? = start
    var depth = 0
    while let view = current, depth < 128 {
      if ViewKind.of(view, insideHosting: false) == .hosting {
        out.append(view)
      }
      if view === stop { break }
      current = view.superview
      depth += 1
    }
    return out
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

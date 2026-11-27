#if canImport(UIKit)
import UIKit

/// The live `.tugboatTag` markers (native SDK note section 6.3). Tags are
/// the first identity source for a tap: SwiftUI drawing has no UIKit view
/// and the in-process accessibility tree is empty.
///
/// A tag matches a tap only inside the hierarchy that was hit: same window,
/// and under the same hosting root (the outermost hosting view above the
/// hit view, or the window). A screen under a sheet, or another window,
/// can therefore never win a tap meant for what covers it; without a match
/// identity falls back to UIKit hit-testing. Frames are read from UIKit at
/// match time, so they are current during scrolls and transitions.
///
/// Markers are held weakly. Main thread only.
final class TagRegistry {
  static let shared = TagRegistry()

  private let markers = NSHashTable<TagMarkerView>.weakObjects()

  func register(_ marker: TagMarkerView) {
    markers.add(marker)
    marker.registry = self
  }

  func unregister(_ marker: TagMarkerView) {
    markers.remove(marker)
  }

  /// Every live marker.
  var all: [TagMarkerView] {
    markers.allObjects
  }

  /// The marker at `point` (window coordinates): the smallest visible
  /// tagged frame containing it among the markers in `window` under `root`.
  func marker(at point: CGPoint, in window: UIWindow, root: UIView) -> TagMarkerView? {
    let hits = all.compactMap { marker -> (marker: TagMarkerView, area: CGFloat)? in
      guard marker.window === window, marker.isDescendant(of: root), isVisible(marker, below: root) else { return nil }
      let frame = marker.convert(marker.bounds, to: window)
      guard !frame.isEmpty, frame.contains(point) else { return nil }
      return (marker, frame.width * frame.height)
    }
    return hits.min { $0.area < $1.area }?.marker
  }

  /// The ordinal of `marker` among the visible markers in its nearest
  /// hosting view, in layout order: top to bottom, then leading to
  /// trailing (window coordinates). It names a tagged target in the
  /// structural path without the tag value.
  func layoutOrdinal(of marker: TagMarkerView) -> Int {
    guard let window = marker.window else { return 0 }
    let root = TagRegistry.nearestHosting(of: marker)
    let peers = all.filter { peer in
      peer.window === window && TagRegistry.nearestHosting(of: peer) === root && isVisible(peer, below: root ?? window)
    }
    let ordered = peers.map { ($0, $0.convert($0.bounds, to: window)) }.sorted { lhs, rhs in
      if lhs.1.minY != rhs.1.minY { return lhs.1.minY < rhs.1.minY }
      if lhs.1.minX != rhs.1.minX { return lhs.1.minX < rhs.1.minX }
      return lhs.1.height < rhs.1.height
    }
    return ordered.firstIndex { $0.0 === marker } ?? 0
  }

  private static func nearestHosting(of view: UIView) -> UIView? {
    var current = view.superview
    var depth = 0
    while let ancestor = current, depth < ViewTree.maxDepth {
      if ViewKind.of(ancestor, insideHosting: false) == .hosting { return ancestor }
      current = ancestor.superview
      depth += 1
    }
    return nil
  }

  /// No hidden or transparent view between the marker and `root`.
  private func isVisible(_ marker: TagMarkerView, below root: UIView) -> Bool {
    var current: UIView? = marker
    while let view = current, view !== root {
      if view.isHidden || view.alpha <= 0.01 { return false }
      current = view.superview
    }
    return true
  }
}
#endif

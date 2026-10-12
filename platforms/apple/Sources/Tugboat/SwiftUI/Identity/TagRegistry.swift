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

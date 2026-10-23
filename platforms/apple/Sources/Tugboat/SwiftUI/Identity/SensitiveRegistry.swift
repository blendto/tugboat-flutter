#if canImport(UIKit)
import UIKit

/// Live `.tugboatSensitive` markers. Their frames are unioned into mask
/// geometry at capture time. Markers are held weakly. Main thread only.
final class SensitiveRegistry {
  static let shared = SensitiveRegistry()

  private let markers = NSHashTable<SensitiveMarkerView>.weakObjects()

  func register(_ marker: SensitiveMarkerView) {
    markers.add(marker)
    marker.registry = self
  }

  func unregister(_ marker: SensitiveMarkerView) {
    markers.remove(marker)
  }

  var all: [SensitiveMarkerView] {
    markers.allObjects
  }

  /// Adds each visible marker in `window` to `acc`.
  func addMasks(in window: UIWindow, into acc: inout MaskAccumulator) {
    for marker in all {
      guard marker.window === window, isVisible(marker) else { continue }
      acc.add(view: marker)
    }
  }

  private func isVisible(_ marker: SensitiveMarkerView) -> Bool {
    var current: UIView? = marker
    while let view = current {
      if view.isHidden || view.alpha <= 0.01 { return false }
      current = view.superview
    }
    return true
  }
}
#endif

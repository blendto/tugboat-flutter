#if canImport(UIKit)
import UIKit

/// The marker for one `.tugboatSensitive` view. The mask walk masks its
/// host's frame where it meets it (`ViewKind.sensitiveMarker`); identity
/// skips it and its host, so sibling ordinals and paths are unchanged.
final class SensitiveMarkerView: MarkerView {
  override func didMoveToSuperview() {
    superview?.isUserInteractionEnabled = true
  }
}
#endif

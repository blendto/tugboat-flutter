#if canImport(UIKit)
import UIKit

/// The UIKit stand-in for one `.tugboatTag` view: an empty, invisible view
/// that SwiftUI lays out behind the tagged content, so the tag's frame,
/// window and hosting root are read from UIKit at tap time instead of being
/// assumed from SwiftUI's coordinate spaces.
///
/// It never takes part in the app: it does not draw, hit-test, or appear to
/// accessibility, and it makes its SwiftUI host ignore touches too. Masks
/// and identity skip it and its host (`ViewKind.sdkOwned`).
final class TagMarkerView: UIView {
  var tugboatTag = ""
  weak var registry: TagRegistry?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isOpaque = false
    backgroundColor = nil
    isAccessibilityElement = false
    accessibilityElementsHidden = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    return nil
  }

  override func didMoveToSuperview() {
    super.didMoveToSuperview()
    superview?.isUserInteractionEnabled = false
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    nil
  }
}
#endif

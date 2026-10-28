#if canImport(UIKit)
import UIKit

/// The UIKit stand-in a Tugboat view modifier lays out behind SwiftUI
/// content (`.tugboatTag`, `.tugboatSensitive`), so the content's frame and
/// window are read from UIKit instead of being assumed from SwiftUI's
/// coordinate spaces.
///
/// It never takes part in the app: it does not draw, hit-test, or appear to
/// accessibility, and it makes its SwiftUI host ignore touches too. Identity
/// skips it and its host (`ViewTree.isExcludedFromIdentity`).
class MarkerView: UIView {
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

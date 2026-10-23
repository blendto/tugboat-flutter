#if canImport(UIKit)
import UIKit

/// The UIKit stand-in for one `.tugboatSensitive` view: an empty, invisible
/// view that SwiftUI lays out behind the marked content so its frame is read
/// from UIKit when masks are computed.
///
/// It never takes part in the app: it does not draw, hit-test, or appear to
/// accessibility, and it makes its SwiftUI host ignore touches too. Identity
/// skips it and its host (`ViewKind.sdkOwned`).
final class SensitiveMarkerView: UIView {
  weak var registry: SensitiveRegistry?

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

#if canImport(UIKit)
import ObjectiveC
import UIKit

/// What the adapter knows a `UIView` to be, shared by identity (section 6.3)
/// and masking (section 2.1). Classification uses public type checks and
/// read-only class-name comparison; it never calls private API.
enum ViewKind: Equatable {
  /// A SwiftUI hosting view (`_UIHostingView<…>` and its variants).
  case hosting
  /// The host of an app's `UIViewRepresentable` /
  /// `UIViewControllerRepresentable`
  /// (`UIKitPlatformViewHost<PlatformViewRepresentableAdaptor<…>>`), or an
  /// app-defined view inside a hosting view. SwiftUI's own platform views
  /// (`List`'s `ListRepresentable`, text fields) are walked like any other
  /// view: what they draw is still masked by class or fail-closed.
  case representable
  /// `UITextField`, `UITextView` (SwiftUI `TextField`, `SecureField`,
  /// `TextEditor`).
  case textInput
  case label
  case image
  case webView
  /// A `UICollectionViewCell` or `UITableViewCell` (SwiftUI `List` rows).
  case cell
  /// Any other `UIScrollView` (SwiftUI `ScrollView`, `List`).
  case scrollView
  case other

  private static let cache = Locked([ObjectIdentifier: ViewKind]())
  private static let webViewClass: AnyClass? = NSClassFromString("WKWebView")

  /// The kind of `view`. `insideHosting` is whether a hosting view is among
  /// its ancestors: there an app-defined view can only come from a
  /// representable.
  static func of(_ view: UIView, insideHosting: Bool) -> ViewKind {
    let kind = classKind(type(of: view))
    if kind == .other, insideHosting, isAppDefined(type(of: view)) {
      return .representable
    }
    return kind
  }

  /// True when `view` should be left out of identity and masks: hidden,
  /// transparent, or without area.
  static func isExcluded(_ view: UIView) -> Bool {
    view.isHidden || view.alpha <= 0.01 || view.bounds.width <= 0 || view.bounds.height <= 0
  }

  private static func classKind(_ cls: UIView.Type) -> ViewKind {
    let key = ObjectIdentifier(cls)
    if let cached = cache.withLock({ $0[key] }) {
      return cached
    }
    let kind = computeKind(cls)
    cache.withLock { $0[key] = kind }
    return kind
  }

  private static func computeKind(_ cls: UIView.Type) -> ViewKind {
    if let web = webViewClass, cls.isSubclass(of: web) { return .webView }
    if cls.isSubclass(of: UITextField.self) || cls.isSubclass(of: UITextView.self) { return .textInput }
    if cls.isSubclass(of: UILabel.self) { return .label }
    if cls.isSubclass(of: UIImageView.self) { return .image }
    if cls.isSubclass(of: UICollectionViewCell.self) || cls.isSubclass(of: UITableViewCell.self) { return .cell }
    if cls.isSubclass(of: UIScrollView.self) { return .scrollView }
    let name = String(describing: cls)
    if name.contains("PlatformViewHost") {
      return name.contains("RepresentableAdaptor") ? .representable : .other
    }
    if name.contains("HostingView") { return .hosting }
    return .other
  }

  /// A class whose code is not in a system image: the app's, or a
  /// third-party framework's. A class without an image (a runtime generic
  /// specialization) counts as a system one.
  private static func isAppDefined(_ cls: AnyClass) -> Bool {
    guard let image = class_getImageName(cls) else { return false }
    let path = String(cString: image)
    return !(path.contains("/System/Library/") || path.hasPrefix("/usr/lib/"))
  }
}
#endif

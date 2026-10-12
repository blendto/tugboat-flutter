#if canImport(UIKit)
import ObjectiveC
import UIKit

/// What the adapter knows a `UIView` to be, shared by identity (section 6.3)
/// and masking (section 2.1). Classification uses public type checks and
/// read-only class-name comparison; it never calls private API. Use
/// `ViewTree` to get a view's kind: it knows whether a hosting view is above.
enum ViewKind: Equatable {
  /// A SwiftUI hosting view (`_UIHostingView<…>`, `CellHostingView<…>`).
  case hosting
  /// Content the SDK cannot see into, masked as a box: a platform-view host
  /// (`UIKitPlatformViewHost<…>`, an app's `UIViewRepresentable`) that is
  /// not a known SwiftUI-internal one, or an app-defined view inside a
  /// hosting view.
  case representable
  /// A SwiftUI-internal platform-view host (`List`, `TextField`) listed in
  /// `KnownPlatformViews`: walked through, and transparent to identity.
  case internalPlatformView
  /// `UITextField`, `UITextView` (SwiftUI `TextField`, `SecureField`,
  /// `TextEditor`).
  case textInput
  case label
  case image
  case webView
  /// A view whose pixels come from outside its layer tree (Metal, video,
  /// remote or portal views): masked as a box.
  case renderer
  /// A `UICollectionViewCell` or `UITableViewCell` (SwiftUI `List` rows).
  case cell
  /// Any other `UIScrollView` (SwiftUI `ScrollView`, `List`).
  case scrollView
  /// A view the SDK itself added (`.tugboatTag` markers and their hosts).
  case sdkOwned
  case other

  private static let cache = Locked([ObjectIdentifier: ViewKind]())
  private static let webViewClass: AnyClass? = NSClassFromString("WKWebView")

  /// The kind of `view`; `insideHosting` is whether a hosting view is among
  /// its ancestors (there an app-defined view can only be a representable).
  static func of(_ view: UIView, insideHosting: Bool) -> ViewKind {
    let cls: UIView.Type = type(of: view)
    let kind = classKind(cls)
    switch kind {
    case .representable, .internalPlatformView:
      return view.subviews.contains { $0 is TagMarkerView } ? .sdkOwned : kind
    case .other:
      return insideHosting && isAppDefined(cls) ? .representable : .other
    default:
      return kind
    }
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
    if cls.isSubclass(of: TagMarkerView.self) { return .sdkOwned }
    if let web = webViewClass, cls.isSubclass(of: web) { return .webView }
    if cls.isSubclass(of: UITextField.self) || cls.isSubclass(of: UITextView.self) { return .textInput }
    if cls.isSubclass(of: UILabel.self) { return .label }
    if cls.isSubclass(of: UIImageView.self) { return .image }
    if cls.isSubclass(of: UICollectionViewCell.self) || cls.isSubclass(of: UITableViewCell.self) { return .cell }
    if cls.isSubclass(of: UIScrollView.self) { return .scrollView }
    let name = String(describing: cls)
    if OpaqueRenderers.isRenderer(layerClass: cls.layerClass) || OpaqueRenderers.isRendererViewName(name) {
      return .renderer
    }
    if name.contains("PlatformViewHost") {
      return KnownPlatformViews.isInternal(name) ? .internalPlatformView : .representable
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

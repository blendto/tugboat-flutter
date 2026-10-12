#if canImport(UIKit)
import UIKit

/// The identity side of `ViewKind` (native SDK note section 6.3): which
/// kinds are untagged tap targets and canonical path segments, and the
/// anchor vocabulary shared with the Flutter and Views adapters.
extension ViewKind {
  /// The canonical path token, or nil when the kind collapses out of paths.
  var token: String? {
    switch self {
    case .hosting: return "Host"
    case .textInput: return "TextField"
    case .cell: return "Cell"
    case .scrollView: return "Scrollable"
    case .representable, .webView, .renderer: return "Representable"
    case .internalPlatformView, .label, .image, .sdkOwned, .other: return nil
    }
  }

  /// Kinds an untagged tap can resolve to. A nested hosting view is a path
  /// segment, never a target on its own.
  var isTarget: Bool {
    token != nil && self != .hosting
  }

  /// The anchor `role`: only kinds with a shared meaning.
  var anchorRole: String? {
    switch self {
    case .textInput: return "textField"
    case .scrollView: return "scrollable"
    default: return nil
    }
  }

  /// The anchor `widgetType`: a public UIKit base class, never an app or
  /// private SwiftUI class name.
  func widgetType(of view: UIView) -> String {
    switch self {
    case .textInput: return view is UITextView ? "UITextView" : "UITextField"
    case .cell: return view is UITableViewCell ? "UITableViewCell" : "UICollectionViewCell"
    case .scrollView: return "UIScrollView"
    case .representable, .webView, .renderer: return "UIViewRepresentable"
    case .hosting: return "UIHostingView"
    default: return "UIView"
    }
  }

  /// Sorted action names; empty when the view is disabled.
  func actions(of view: UIView) -> [String] {
    guard ViewKind.isEnabled(view) != false else { return [] }
    switch self {
    case .textInput: return ["input", "tap"]
    case .cell: return ["tap"]
    case .scrollView: return ["scroll"]
    default: return []
    }
  }

  /// `enabled` for controls and text views; nil where UIKit has no notion.
  static func isEnabled(_ view: UIView) -> Bool? {
    if let control = view as? UIControl {
      return control.isEnabled
    }
    if let textView = view as? UITextView {
      return textView.isEditable
    }
    return nil
  }
}
#endif

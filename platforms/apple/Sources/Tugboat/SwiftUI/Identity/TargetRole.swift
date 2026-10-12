#if canImport(UIKit)
import UIKit

/// The UIKit role of a view that can be an untagged target or a canonical
/// path segment (native SDK note section 6.3). `token` is the path token;
/// the anchor's `role` and `actions` use the vocabulary shared with the
/// Flutter and Views adapters.
enum TargetRole: String {
  case textField = "TextField"
  case cell = "Cell"
  case scrollable = "Scrollable"
  case representable = "Representable"
  /// A nested hosting view: a path segment, never a target on its own.
  case host = "Host"

  var token: String {
    rawValue
  }

  /// Roles an untagged tap can resolve to.
  var isTarget: Bool {
    self != .host
  }

  static func of(_ view: UIView, insideHosting: Bool) -> TargetRole? {
    switch ViewKind.of(view, insideHosting: insideHosting) {
    case .textInput: return .textField
    case .cell: return .cell
    case .scrollView: return .scrollable
    case .representable, .webView: return .representable
    case .hosting: return .host
    case .label, .image, .other: return nil
    }
  }

  /// The anchor `role`: only roles with a shared meaning.
  var anchorRole: String? {
    switch self {
    case .textField: return "textField"
    case .scrollable: return "scrollable"
    case .cell, .representable, .host: return nil
    }
  }

  /// The anchor `widgetType`: a public UIKit base class, never an app or
  /// private SwiftUI class name.
  func widgetType(of view: UIView) -> String {
    switch self {
    case .textField: return view is UITextView ? "UITextView" : "UITextField"
    case .cell: return view is UITableViewCell ? "UITableViewCell" : "UICollectionViewCell"
    case .scrollable: return "UIScrollView"
    case .representable: return "UIViewRepresentable"
    case .host: return "UIHostingView"
    }
  }

  /// Sorted action names; empty when the view is disabled.
  func actions(of view: UIView) -> [String] {
    guard TargetRole.isEnabled(view) != false else { return [] }
    switch self {
    case .textField: return ["input", "tap"]
    case .cell: return ["tap"]
    case .scrollable: return ["scroll"]
    case .representable, .host: return []
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

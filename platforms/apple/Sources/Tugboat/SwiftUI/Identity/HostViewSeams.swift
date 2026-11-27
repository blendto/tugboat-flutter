#if canImport(UIKit)
import ObjectiveC
import UIKit

/// What a framework that draws plain UIKit views (React Native) tells the
/// adapter about them, through `TugboatAdapters`: a name for a view (a
/// `testID`), the role of a view class that draws text or images itself, and
/// views that must be masked. Nothing here is set unless the framework's
/// adapter sets it, so a SwiftUI app is unchanged.
enum HostViewSeams {
  private struct State {
    var nameProvider: ((UIView) -> String?)?
    var roleClassifier: ((AnyClass) -> TugboatViewRole?)?
  }

  private static let state = Locked(State())
  private static var sensitiveKey: UInt8 = 0

  static func setNameProvider(_ provider: ((UIView) -> String?)?) {
    state.withLock { $0.nameProvider = provider }
  }

  /// Also forgets the classes already classified, which the classifier may
  /// now decide differently.
  static func setRoleClassifier(_ classifier: ((AnyClass) -> TugboatViewRole?)?) {
    state.withLock { $0.roleClassifier = classifier }
    ViewKind.forgetClassifiedKinds()
  }

  /// The host's name for `view`, trimmed; nil when there is no provider or
  /// the name is blank. Main thread.
  static func name(of view: UIView) -> String? {
    guard let provider = state.withLock({ $0.nameProvider }), let name = provider(view) else { return nil }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func role(of cls: AnyClass) -> TugboatViewRole? {
    state.withLock({ $0.roleClassifier })?(cls)
  }

  static func markSensitive(_ view: UIView) {
    objc_setAssociatedObject(view, &sensitiveKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
  }

  static func isSensitive(_ view: UIView) -> Bool {
    (objc_getAssociatedObject(view, &sensitiveKey) as? Bool) == true
  }
}
#endif

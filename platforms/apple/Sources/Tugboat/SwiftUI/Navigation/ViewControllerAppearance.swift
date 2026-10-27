#if canImport(UIKit)
import ObjectiveC
import UIKit

/// Optional view-controller appearance tracking (native SDK note section 5):
/// `viewDidAppear` / `viewDidDisappear` of `UIViewController` are exchanged,
/// once per process, with implementations that call the original and then
/// tell `observer`. Only public Objective-C runtime functions are used
/// (`class_getInstanceMethod`, `method_exchangeImplementations`).
///
/// It is installed the first time a session starts with
/// `trackHostingControllers` (never while Tugboat is dormant, never when the
/// configuration opts out), so a hosting controller already on screen at
/// that first session start is not seen; `.tugboatScreen` alone is enough
/// for route keys. It is never exchanged back, not even by
/// `Tugboat.deactivate()` or `Tugboat.stop()`: another SDK may have
/// exchanged the same methods since, and undoing ours would break its
/// chain. While no session records, the exchanged methods call the
/// originals and record nothing.
///
/// Main thread only.
enum ViewControllerAppearance {
  private static let installed = Locked(false)

  /// Called after every view controller's `viewDidAppear` (true) or
  /// `viewDidDisappear` (false).
  static var observer: ((UIViewController, Bool) -> Void)?

  static var isInstalled: Bool {
    installed.current
  }

  static func install() {
    let first = installed.withLock { (done: inout Bool) -> Bool in
      defer { done = true }
      return !done
    }
    guard first else { return }
    exchange(#selector(UIViewController.viewDidAppear(_:)), with: #selector(UIViewController.tugboat_viewDidAppear(_:)))
    exchange(#selector(UIViewController.viewDidDisappear(_:)), with: #selector(UIViewController.tugboat_viewDidDisappear(_:)))
  }

  fileprivate static func notify(_ controller: UIViewController, appeared: Bool) {
    observer?(controller, appeared)
  }

  private static func exchange(_ original: Selector, with replacement: Selector) {
    guard
      let originalMethod = class_getInstanceMethod(UIViewController.self, original),
      let replacementMethod = class_getInstanceMethod(UIViewController.self, replacement)
    else {
      AdapterLog.once("view controller appearance", "\(original) not found; not tracking it")
      return
    }
    method_exchangeImplementations(originalMethod, replacementMethod)
  }
}

extension UIViewController {
  /// After the exchange this name runs the original `viewDidAppear`.
  @objc fileprivate func tugboat_viewDidAppear(_ animated: Bool) {
    tugboat_viewDidAppear(animated)
    ViewControllerAppearance.notify(self, appeared: true)
  }

  /// After the exchange this name runs the original `viewDidDisappear`.
  @objc fileprivate func tugboat_viewDidDisappear(_ animated: Bool) {
    tugboat_viewDidDisappear(animated)
    ViewControllerAppearance.notify(self, appeared: false)
  }
}
#endif

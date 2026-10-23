#if canImport(UIKit)
import UIKit

/// The route a target belongs to (native SDK note section 6.3), in priority
/// order:
///
/// 1. the name of the `.tugboatScreen` on top of the visible chain of
///    navigators (`ScreenTracker.visibleTop`): `high`;
/// 2. the nearest hosting controller's Swift type name, hashed because it is
///    long (`host:<16 hex>`): `medium`. Swift type names are not
///    obfuscated, but a type name changes when the view tree's type does.
///    A type-erased root (`AnyView` anywhere in the type) names no screen,
///    so every such controller shares a key: `low`;
/// 3. `swiftui:window` when the target is in no hosting controller: `low`.
///
/// `root` is the view canonical paths start below: that hosting
/// controller's view, else the window.
struct RouteKey: Equatable {
  static let windowKey = "swiftui:window"

  let value: String
  let confidence: Confidence
  let root: UIView

  static func resolve(for view: UIView, in window: UIWindow, screen: RouteEntry?) -> RouteKey {
    let controller = hostingController(of: view)
    let root = controller?.viewIfLoaded ?? window
    if let name = screen?.name, !name.isEmpty {
      return RouteKey(value: name, confidence: .high, root: root)
    }
    if let controller = controller {
      let erased = String(reflecting: type(of: controller)).contains("AnyView")
      return RouteKey(value: hostingKey(controller), confidence: erased ? .low : .medium, root: root)
    }
    return RouteKey(value: windowKey, confidence: .low, root: window)
  }

  /// `host:<16 hex>` of the controller's fully qualified type name.
  static func hostingKey(_ controller: UIViewController) -> String {
    let typeName = String(reflecting: type(of: controller))
    return "host:" + IdentityHash.fingerprint([(key: "hostingType", value: typeName)])
  }

  /// The nearest hosting controller whose view contains `view`, found
  /// through the responder chain.
  static func hostingController(of view: UIView) -> UIViewController? {
    var responder: UIResponder? = view
    while let current = responder {
      if let controller = current as? UIViewController, isHostingController(controller) {
        return controller
      }
      responder = current.next
    }
    return nil
  }

  static func isHostingController(_ controller: UIViewController) -> Bool {
    String(describing: type(of: controller)).contains("HostingController")
  }
}
#endif

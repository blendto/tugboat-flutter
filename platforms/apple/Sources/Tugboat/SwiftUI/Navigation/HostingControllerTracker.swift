#if canImport(UIKit)
import UIKit

/// Navigation facts from hosting-controller appearance, for apps that do
/// not use `.tugboatScreen` (native SDK note sections 5 and 6.3).
///
/// - Only hosting controllers whose view covers at least half the window
///   count as screens (not bar items or small embedded hosts).
/// - Each controller is one route on navigator `swiftui-hosting`, named by
///   its hashed type (`host:<16 hex>`, the same route key identity uses).
/// - Once any `.tugboatScreen` has appeared in the process it stays silent,
///   so a route is never reported by both sources.
///
/// Main thread only.
final class HostingControllerTracker {
  static let navigatorId = "swiftui-hosting"
  static let routeType = "UIHostingController"

  private let screens: ScreenTracker
  private let clock: FactClock
  private let emit: (AdapterFact) -> Void
  private var stack = ScreenStack(navigatorId: HostingControllerTracker.navigatorId)
  private let ids = ObjectIds(prefix: "swiftui-host")

  init(screens: ScreenTracker, clock: FactClock, emit: @escaping (AdapterFact) -> Void) {
    self.screens = screens
    self.clock = clock
    self.emit = emit
  }

  /// A disappearing controller is matched by identity: its view has usually
  /// left the window by then, so its size can no longer be checked.
  func controller(_ controller: UIViewController, appeared: Bool) {
    guard !screens.hasSeenScreen, RouteKey.isHostingController(controller) else { return }
    let change: NavigationChange?
    if appeared {
      guard coversWindow(controller) else { return }
      let entry = RouteEntry(
        instanceId: ids.id(of: controller),
        name: RouteKey.hostingKey(controller),
        type: HostingControllerTracker.routeType
      )
      change = stack.appeared(entry)
    } else {
      guard let known = ids.existingId(of: controller) else { return }
      change = stack.disappeared(instanceId: known)
    }
    if let change = change {
      emit(change.fact(at: clock.now()))
    }
  }

  private func coversWindow(_ controller: UIViewController) -> Bool {
    guard let view = controller.viewIfLoaded, let window = view.window else { return false }
    let windowArea = window.bounds.width * window.bounds.height
    guard windowArea > 0 else { return false }
    let frame = view.convert(view.bounds, to: window).intersection(window.bounds)
    guard !frame.isNull else { return false }
    return frame.width * frame.height >= windowArea / 2
  }
}
#endif

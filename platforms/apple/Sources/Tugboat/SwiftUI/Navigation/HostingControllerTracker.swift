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
/// - The stack survives adapter stop/start; `session_start` is emitted only
///   from [sessionStartFact] while live changes respect [isRecording].
///
/// Main thread only.
final class HostingControllerTracker {
  static let shared = HostingControllerTracker()
  static let navigatorId = "swiftui-hosting"
  static let routeType = "UIHostingController"

  private let screens: ScreenTracker
  private let clock: FactClock
  private var stack = ScreenStack(navigatorId: HostingControllerTracker.navigatorId)
  private let ids = ObjectIds(prefix: "swiftui-host")
  private var facts: [AdapterFact] = []

  /// Live facts are produced only while true (the adapter is running).
  var isRecording = false

  init(screens: ScreenTracker = .shared, clock: HostClock = SystemHostClock()) {
    self.screens = screens
    self.clock = FactClock(clock: clock)
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
    record(change, at: clock.now())
  }

  func beginSession() {}

  func sessionStartFact(at: HostTime) -> AdapterFact? {
    guard !screens.hasSeenScreen, !stack.entries.isEmpty else { return nil }
    return NavigationChange(sessionStart: HostingControllerTracker.navigatorId, routes: stack.entries).fact(at: at)
  }

  func takeFacts() -> [AdapterFact] {
    defer { facts.removeAll() }
    return facts
  }

  func reset() {
    facts.removeAll()
    stack.removeAll()
  }

  private func record(_ change: NavigationChange?, at: HostTime) {
    guard isRecording, let change = change else { return }
    facts.append(change.fact(at: at))
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

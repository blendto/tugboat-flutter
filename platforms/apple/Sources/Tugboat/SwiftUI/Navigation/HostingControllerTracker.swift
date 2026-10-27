#if canImport(UIKit)
import UIKit

/// Navigation facts from hosting-controller appearance, for apps that do
/// not use `.tugboatScreen` (native SDK note sections 5 and 6.3).
///
/// - Only hosting controllers whose view covers at least half the window
///   count as screens (not bar items or small embedded hosts).
/// - Each controller is one route on navigator `swiftui-hosting`, named by
///   its hashed type (`host:<16 hex>`, the same route key identity uses),
///   with `overlayKind` `page` (presentation is not read from UIKit).
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

  private var screens: ScreenTracker
  private var clock: HostClock
  private var stack = ScreenStack(navigatorId: HostingControllerTracker.navigatorId)
  private let ids = ObjectIds(prefix: "swiftui-host")
  private var facts: [AdapterFact] = []
  private var requestFrame: (() -> Void)?

  /// Live facts are produced only while true (the adapter is running).
  var isRecording = false

  init(screens: ScreenTracker = .shared, clock: HostClock = SystemHostClock()) {
    self.screens = screens
    self.clock = clock
  }

  /// Binds the adapter's screen registry, clock, and frame scheduler (process-scoped stack).
  func bind(screens: ScreenTracker, clock: HostClock, requestFrame: @escaping () -> Void) {
    self.screens = screens
    self.clock = clock
    self.requestFrame = requestFrame
  }

  private static var appearanceInstalled = false

  /// Installs the process-wide `UIViewController` appearance exchange the
  /// first time an adapter that tracks hosting controllers starts (the
  /// first session start, never while dormant); an app that opts out
  /// (`trackHostingControllers: false`) is never swizzled. It stays
  /// installed after `deactivate()` and `stop()` and records nothing while
  /// no adapter is recording.
  func installAppearanceObserverIfNeeded() {
    guard !HostingControllerTracker.appearanceInstalled else { return }
    HostingControllerTracker.appearanceInstalled = true
    ViewControllerAppearance.observer = { controller, appeared in
      HostingControllerTracker.shared.controller(controller, appeared: appeared)
    }
    ViewControllerAppearance.install()
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
        type: HostingControllerTracker.routeType,
        overlayKind: .page
      )
      change = stack.appeared(entry)
    } else {
      guard let known = ids.existingId(of: controller) else { return }
      change = stack.disappeared(instanceId: known)
    }
    record(change, at: clock.now())
  }

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
    guard let change = change else { return }
    if isRecording {
      facts.append(change.fact(at: at))
      requestFrame?()
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

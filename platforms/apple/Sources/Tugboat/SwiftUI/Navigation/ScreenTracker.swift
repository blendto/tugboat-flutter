import Foundation

/// The `.tugboatScreen` registry: which screens are on screen, in what
/// order, and the navigation facts their appear and disappear callbacks
/// imply (native SDK note sections 5 and 6.3; stateful-engine.md 8.1).
///
/// - Every screen modifier instance is one route with a stable opaque
///   `instanceId`, on one navigator (`swiftui-screens`).
/// - Callbacks are queued and applied together on the next frame,
///   appearances first. SwiftUI does not order `onAppear` and
///   `onDisappear` of two screens consistently within a frame; applying
///   appearances first keeps a covered screen on the stack instead of
///   popping it.
/// - `top` is the route key source for identity. It is kept even while the
///   adapter is not recording; facts are only kept while it is.
///
/// Main thread only (SwiftUI runs view callbacks there).
final class ScreenTracker {
  static let shared = ScreenTracker()
  static let navigatorId = "swiftui-screens"
  static let routeType = "TugboatScreen"
  private static let nextInstance = Locked<Int64>(1)

  private enum Event {
    case appeared(RouteEntry, HostTime)
    case disappeared(String, HostTime)
  }

  private let clock: HostClock
  private var stack = ScreenStack(navigatorId: ScreenTracker.navigatorId)
  private var queued: [Event] = []
  private var facts: [AdapterFact] = []

  /// Facts are produced only while true (the adapter is running).
  var isRecording = false
  /// Runs after each callback, so the adapter can request a frame.
  var onEvent: (() -> Void)?
  /// True once any screen appeared in this process; hosting-controller
  /// navigation then stays silent so routes are not reported twice.
  private(set) var hasSeenScreen = false

  init(clock: HostClock = SystemHostClock()) {
    self.clock = clock
  }

  static func newInstanceId() -> String {
    let id = nextInstance.withLock { (next: inout Int64) -> Int64 in
      defer { next = next == Int64.max ? 1 : next + 1 }
      return next
    }
    return "swiftui-screen-\(id)"
  }

  /// The most recently shown screen that is still on the stack.
  var top: RouteEntry? {
    settle()
    return stack.top
  }

  func appeared(instanceId: String, name: String) {
    hasSeenScreen = true
    let entry = RouteEntry(instanceId: instanceId, name: name, type: ScreenTracker.routeType)
    queued.append(.appeared(entry, clock.now()))
    onEvent?()
  }

  func disappeared(instanceId: String) {
    queued.append(.disappeared(instanceId, clock.now()))
    onEvent?()
  }

  /// Applies queued callbacks and returns the facts recorded so far.
  func takeFacts() -> [AdapterFact] {
    settle()
    defer { facts.removeAll() }
    return facts
  }

  /// Forgets every screen and queued callback (tests, and adapter stop).
  func reset() {
    queued.removeAll()
    facts.removeAll()
    stack.removeAll()
  }

  private func settle() {
    guard !queued.isEmpty else { return }
    let events = queued
    queued.removeAll()
    for case let .appeared(entry, at) in events {
      record(stack.appeared(entry), at: at)
    }
    for case let .disappeared(instanceId, at) in events {
      record(stack.disappeared(instanceId: instanceId), at: at)
    }
  }

  private func record(_ change: NavigationChange?, at: HostTime) {
    guard isRecording, let change = change else { return }
    facts.append(change.fact(at: at))
  }
}

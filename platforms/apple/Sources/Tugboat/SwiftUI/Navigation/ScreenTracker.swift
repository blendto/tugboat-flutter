import Foundation

/// The `.tugboatScreen` registry: which screens are on screen, on which
/// navigator, in what order, and the navigation facts their appear and
/// disappear callbacks imply (native SDK note sections 5 and 6.3;
/// stateful-engine.md 8.1).
///
/// - Every screen modifier instance is one route with a stable opaque
///   `instanceId`, on the navigator its environment names (`NavigatorScope`):
///   the root `swiftui-screens`, or `swiftui-screens/<name>` inside
///   `.tugboatNavigator(name)`, whose facts carry `parentNavigatorId`. A
///   sheet's screen is a route on the navigator that presented it.
/// - Callbacks are queued and applied together on the next frame,
///   appearances first. SwiftUI does not order `onAppear` and
///   `onDisappear` of two screens consistently within a frame; applying
///   appearances first keeps a covered screen on the stack instead of
///   popping it.
/// - A nested navigator is forgotten, with no fact, once its host route has
///   left the parent's stack, once its parent is forgotten, or once its
///   stack is empty and no navigator below it remains (Android forgets a
///   fragment navigator whose host left the same way).
/// - `visibleTop` is the route key source for identity: the top of the
///   visible chain as of the last `settle()` (identity settles before
///   reading it). The stacks are kept even while the adapter is not
///   recording; facts are only kept while it is.
///
/// Main thread only (SwiftUI runs view callbacks there).
final class ScreenTracker {
  static let shared = ScreenTracker()
  static let navigatorId = "swiftui-screens"
  static let routeType = "TugboatScreen"
  private static let instances = IdSequence()

  private enum Event {
    case appeared(RouteEntry, NavigatorScope, HostTime)
    case disappeared(String, HostTime)
  }

  /// One navigator: its stack (which knows its parent), the route on the
  /// parent's stack that hosts it, and when it or a navigator below it
  /// last changed.
  private struct Navigator {
    var stack: ScreenStack
    let hostRouteInstanceId: String?
    /// True once the host route was seen on the parent's stack; only then
    /// can it leave. Callbacks of one SwiftUI update arrive together, but a
    /// host seen a frame late must not drop the navigator first.
    var hostSeen = false
    var lastActive: Int64 = 0

    init(navigatorId: String, parentNavigatorId: String?, hostRouteInstanceId: String?) {
      stack = ScreenStack(navigatorId: navigatorId, parentNavigatorId: parentNavigatorId)
      self.hostRouteInstanceId = hostRouteInstanceId
    }

    static var root: Navigator {
      Navigator(navigatorId: ScreenTracker.navigatorId, parentNavigatorId: nil, hostRouteInstanceId: nil)
    }
  }

  private let clock: HostClock
  private var navigators: [String: Navigator] = [ScreenTracker.navigatorId: .root]
  private var activity: Int64 = 0
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
    instances.nextId(prefix: "swiftui-screen")
  }

  /// The top route of the visible chain, as of the last `settle()`: from
  /// the root navigator down through the navigators its top routes host
  /// (the most recently changed one where several are uncovered), the
  /// deepest non-empty stack's top. It is the route the last
  /// `session_start` seed ends on.
  var visibleTop: RouteEntry? {
    seedOrder().last?.top
  }

  /// The known navigators, sorted (tests and diagnostics).
  var navigatorIds: [String] {
    navigators.keys.sorted()
  }

  /// `navigatorId`'s stack, bottom first; nil when it is not known.
  func entries(of navigatorId: String) -> [RouteEntry]? {
    navigators[navigatorId]?.stack.entries
  }

  func appeared(instanceId: String, name: String, overlayKind: OverlayKind = .page, scope: NavigatorScope = .root) {
    hasSeenScreen = true
    let entry = RouteEntry(instanceId: instanceId, name: name, type: ScreenTracker.routeType, overlayKind: overlayKind)
    queued.append(.appeared(entry, scope, clock.now()))
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

  /// Forgets every screen, navigator and queued callback (tests, and
  /// adapter stop).
  func reset() {
    queued.removeAll()
    facts.removeAll()
    navigators = [ScreenTracker.navigatorId: .root]
    activity = 0
    hasSeenScreen = false
  }

  /// One `session_start` per navigator with a non-empty stack, in
  /// `seedOrder()`: navigators hosted by covered routes first, the visible
  /// chain last (the engine takes the last seed's top as the visible route).
  func sessionStartFacts(at: HostTime) -> [AdapterFact] {
    settle()
    return seedOrder().map { stack in
      NavigationChange(sessionStart: stack.navigatorId, parentNavigatorId: stack.parentNavigatorId, routes: stack.entries)
        .fact(at: at)
    }
  }

  /// Applies queued callbacks: appearances first, then disappearances, then
  /// forgets the navigators that left.
  func settle() {
    guard !queued.isEmpty else { return }
    let events = queued
    queued.removeAll()
    for case let .appeared(entry, scope, at) in events {
      register(scope)
      record(change(on: scope.navigatorId) { $0.appeared(entry) }, at: at)
    }
    for case let .disappeared(instanceId, at) in events {
      // Only a top route's disappearance changes a stack.
      guard let id = navigators.first(where: { $0.value.stack.top?.instanceId == instanceId })?.key else { continue }
      record(change(on: id) { $0.disappeared(instanceId: instanceId) }, at: at)
    }
    forgetLeftNavigators()
  }

  /// Makes every navigator around `scope` known. A known navigator keeps
  /// the parent and host it was first seen with, as the engine keeps the
  /// first parent it learns.
  private func register(_ scope: NavigatorScope) {
    for level in scope.levels where navigators[level.navigatorId] == nil {
      navigators[level.navigatorId] = Navigator(
        navigatorId: level.navigatorId,
        parentNavigatorId: level.parentNavigatorId,
        hostRouteInstanceId: level.hostRouteInstanceId
      )
    }
  }

  private func change(on navigatorId: String, _ apply: (inout ScreenStack) -> NavigationChange?) -> NavigationChange? {
    guard var navigator = navigators[navigatorId] else { return nil }
    let change = apply(&navigator.stack)
    navigators[navigatorId] = navigator
    if change != nil {
      markActive(navigatorId)
    }
    return change
  }

  /// Stamps `navigatorId` and its ancestors as the most recently changed.
  private func markActive(_ navigatorId: String) {
    activity += 1
    var next: String? = navigatorId
    var hops = 0
    while let id = next, hops <= navigators.count, var navigator = navigators[id] {
      navigator.lastActive = activity
      navigators[id] = navigator
      next = navigator.stack.parentNavigatorId
      hops += 1
    }
  }

  private func forgetLeftNavigators() {
    for (id, navigator) in navigators where !navigator.hostSeen && isHostOnParent(navigator) {
      navigators[id]?.hostSeen = true
    }
    var forgotten = true
    while forgotten {
      forgotten = false
      for (id, navigator) in navigators where id != ScreenTracker.navigatorId && hasLeft(id, navigator) {
        navigators[id] = nil
        forgotten = true
      }
    }
  }

  /// The parent is gone, the host route left the parent's stack, or the
  /// stack is empty with no navigator below it.
  private func hasLeft(_ id: String, _ navigator: Navigator) -> Bool {
    guard let parent = navigator.stack.parentNavigatorId, navigators[parent] != nil else { return true }
    if navigator.hostSeen, navigator.hostRouteInstanceId != nil, !isHostOnParent(navigator) {
      return true
    }
    return navigator.stack.entries.isEmpty && !navigators.values.contains { $0.stack.parentNavigatorId == id }
  }

  private func isHostOnParent(_ navigator: Navigator) -> Bool {
    guard let host = navigator.hostRouteInstanceId, let parent = navigator.stack.parentNavigatorId else { return false }
    return navigators[parent]?.stack.contains(instanceId: host) ?? false
  }

  /// The non-empty stacks in seed order (Android `sessionStartSnapshots`).
  /// From the root, for each navigator: the navigators hosted by its
  /// covered routes, then its own stack, then the navigators under its top
  /// route or hosted by no route, least recently changed first. A
  /// navigator whose host route is not on its parent's stack is not
  /// visited: it cannot be visible.
  private func seedOrder() -> [ScreenStack] {
    var out: [ScreenStack] = []
    var visited: Set<String> = []
    visit(ScreenTracker.navigatorId, into: &out, visited: &visited)
    return out
  }

  private func visit(_ id: String, into out: inout [ScreenStack], visited: inout Set<String>) {
    guard let navigator = navigators[id], visited.insert(id).inserted else { return }
    let top = navigator.stack.top?.instanceId
    let children = navigators.filter { $0.value.stack.parentNavigatorId == id }
    let covered = children
      .filter { $0.value.hostRouteInstanceId != nil && $0.value.hostRouteInstanceId != top && isHostOnParent($0.value) }
      .map { $0.key }
      .sorted()
    let uncovered = children
      .filter { $0.value.hostRouteInstanceId == nil || $0.value.hostRouteInstanceId == top }
      .sorted { ($0.value.lastActive, $0.key) < ($1.value.lastActive, $1.key) }
      .map { $0.key }
    covered.forEach { visit($0, into: &out, visited: &visited) }
    if !navigator.stack.entries.isEmpty {
      out.append(navigator.stack)
    }
    uncovered.forEach { visit($0, into: &out, visited: &visited) }
  }

  private func record(_ change: NavigationChange?, at: HostTime) {
    guard isRecording, let change = change else { return }
    facts.append(change.fact(at: at))
  }
}

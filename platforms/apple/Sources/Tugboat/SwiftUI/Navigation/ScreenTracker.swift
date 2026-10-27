import Foundation

/// The `.tugboatScreen` registry: which screens are on screen, on which
/// navigator, in what order, and the navigation facts their appear and
/// disappear callbacks imply (native SDK note sections 5 and 6.3;
/// stateful-engine.md 8.1).
///
/// - Every screen modifier instance is one route with a stable opaque
///   `instanceId`, on the navigator its environment names (`NavigatorScope`):
///   the root `swiftui-screens`, or `swiftui-screens/<name>` inside
///   `.tugboatNavigator(name)`, whose facts carry `parentNavigatorId`.
/// - Callbacks are queued and applied together on the next frame,
///   appearances first. SwiftUI does not order `onAppear` and
///   `onDisappear` of two screens consistently within a frame; applying
///   appearances first keeps a covered screen on the stack instead of
///   popping it. What a callback means for the navigators (covered or
///   popped, which navigators are forgotten, the visible chain) is
///   `NavigatorTree`'s.
/// - `visibleTop` is the route key source for identity: the top of the
///   visible chain, computed at the end of each `settle()` (identity settles
///   before reading it). The stacks are kept even while the adapter is not
///   recording; facts are only kept while it is.
/// - While not recording (Tugboat dormant, deactivated, or stopped) nothing
///   grows with time: callbacks are settled on the main queue's next turn
///   (one coalesced hop, which keeps a frame's callbacks together), and at
///   once when `maxIdleQueue` are pending; navigator ids issued while idle
///   are released. Only the navigators' current stacks are kept, which is
///   what the next session's `session_start` seed needs.
///
/// Main thread only (SwiftUI runs view callbacks there).
final class ScreenTracker {
  static let shared = ScreenTracker()
  static let navigatorId = NavigatorScope.rootNavigatorId
  static let routeType = "TugboatScreen"
  /// Pending callbacks that force a settle while not recording.
  static let maxIdleQueue = 64
  private static let instances = IdSequence()

  private enum Event {
    case appeared(RouteEntry, NavigatorScope, HostTime)
    case disappeared(String, HostTime)
  }

  private let clock: HostClock
  private var tree = NavigatorTree()
  /// `tree.visibleChain()` as of the last `settle()`.
  private var chain: [ScreenStack] = []
  private var queued: [Event] = []
  private var facts: [AdapterFact] = []
  private let scheduleIdleSettle: (@escaping () -> Void) -> Void
  private var idleSettleScheduled = false

  /// Facts are produced only while true (the adapter is running).
  var isRecording = false
  /// Runs after each callback, so the adapter can request a frame.
  var onEvent: (() -> Void)?
  /// True once any screen appeared in this process; hosting-controller
  /// navigation then stays silent so routes are not reported twice.
  private(set) var hasSeenScreen = false

  /// `scheduleIdleSettle` runs a settle while not recording; the main
  /// queue's next turn by default.
  init(
    clock: HostClock = SystemHostClock(),
    scheduleIdleSettle: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
  ) {
    self.clock = clock
    self.scheduleIdleSettle = scheduleIdleSettle
  }

  /// Callbacks not yet settled (tests).
  var queuedCount: Int {
    queued.count
  }

  static func newInstanceId() -> String {
    instances.nextId(prefix: "swiftui-screen")
  }

  /// The top route of the visible chain as of the last `settle()`: the
  /// route the last `session_start` seed ends on.
  var visibleTop: RouteEntry? {
    chain.last?.top
  }

  /// The known navigators, sorted (tests and diagnostics).
  var navigatorIds: [String] {
    tree.ids
  }

  /// `navigatorId`'s stack, bottom first; nil when it is not known. The
  /// argument is the `NavigatorScope` id (`swiftui-screens/<name>`).
  func entries(of navigatorId: String) -> [RouteEntry]? {
    tree.entries(of: navigatorId)
  }

  /// The id sent to the engine for the navigator `swiftui-screens/<name>`:
  /// the bare id when it is free in the session, else `…#<n>`; an id is
  /// never issued twice in a session.
  func engineNavigatorId(of navigatorId: String) -> String? {
    tree.navigatorId(of: navigatorId)
  }

  /// A new session (adapter `start()`): the live navigators keep their ids
  /// (the seeds use them), and only those ids stay issued.
  func beginSession() {
    tree.resetIncarnations()
  }

  func appeared(instanceId: String, name: String, overlayKind: OverlayKind = .page, scope: NavigatorScope = .root) {
    hasSeenScreen = true
    let entry = RouteEntry(instanceId: instanceId, name: name, type: ScreenTracker.routeType, overlayKind: overlayKind)
    enqueue(.appeared(entry, scope, clock.now()))
  }

  func disappeared(instanceId: String) {
    enqueue(.disappeared(instanceId, clock.now()))
  }

  private func enqueue(_ event: Event) {
    queued.append(event)
    onEvent?()
    guard !isRecording else { return }
    if queued.count >= ScreenTracker.maxIdleQueue {
      settleIdle()
      return
    }
    guard !idleSettleScheduled else { return }
    idleSettleScheduled = true
    scheduleIdleSettle { [weak self] in
      guard let self = self else { return }
      self.idleSettleScheduled = false
      if !self.isRecording {
        self.settleIdle()
      }
    }
  }

  /// A settle while no session records: nothing is recorded, and the
  /// navigator ids issued meanwhile are released (the next session's
  /// `beginSession` would release them anyway).
  private func settleIdle() {
    settle()
    tree.resetIncarnations()
  }

  /// Applies queued callbacks and returns the facts recorded so far.
  func takeFacts() -> [AdapterFact] {
    settle()
    defer { facts.removeAll() }
    return facts
  }

  /// Forgets every screen, navigator and queued callback (tests only: the
  /// stacks deliberately survive adapter stop and start).
  func reset() {
    queued.removeAll()
    facts.removeAll()
    tree = NavigatorTree()
    chain = []
    hasSeenScreen = false
  }

  /// One `session_start` per navigator with a non-empty stack, in the
  /// visible chain's seed order (the engine takes the last seed's top as
  /// the visible route).
  func sessionStartFacts(at: HostTime) -> [AdapterFact] {
    settle()
    return chain.map { stack in
      NavigationChange(sessionStart: stack.navigatorId, parentNavigatorId: stack.parentNavigatorId, routes: stack.entries)
        .fact(at: at)
    }
  }

  /// Applies queued callbacks: appearances first, then disappearances
  /// (which see the batch's appearances on screen), then forgets the
  /// navigators that left and recomputes the visible chain.
  func settle() {
    guard !queued.isEmpty else { return }
    let events = queued
    queued.removeAll()
    for case let .appeared(entry, scope, at) in events {
      tree.register(scope)
      record(tree.appeared(entry, on: scope.navigatorId), at: at)
    }
    for case let .disappeared(instanceId, at) in events {
      record(tree.disappeared(instanceId: instanceId), at: at)
    }
    tree.prune()
    chain = tree.visibleChain()
  }

  private func record(_ change: NavigationChange?, at: HostTime) {
    guard isRecording, let change = change else { return }
    facts.append(change.fact(at: at))
  }
}

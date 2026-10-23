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
///
/// Main thread only (SwiftUI runs view callbacks there).
final class ScreenTracker {
  static let shared = ScreenTracker()
  static let navigatorId = NavigatorScope.rootNavigatorId
  static let routeType = "TugboatScreen"
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
  /// the same for its first incarnation in the session, `…#<n>` after it
  /// was forgotten and used again.
  func engineNavigatorId(of navigatorId: String) -> String? {
    tree.navigatorId(of: navigatorId)
  }

  /// A new session (adapter `start()`): a name forgotten from now on gets
  /// its bare id again on its next use. Live navigators keep their ids.
  func beginSession() {
    tree.resetIncarnations()
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

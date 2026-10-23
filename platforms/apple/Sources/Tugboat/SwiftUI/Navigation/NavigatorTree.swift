/// The navigators behind `ScreenTracker`, as a pure value: one stack per
/// navigator, each nested navigator's parent and host route, which entries
/// are on screen, and the order of appearances. It decides what a callback
/// means; `ScreenTracker` only queues callbacks and records the facts.
///
/// **Same-frame assumption.** A real pop delivers the revealed screen's
/// `onAppear` in the same settle batch as the leaving top's `onDisappear`
/// (and a tab switch delivers the shown tab's `onAppear` with the hidden
/// tab's `onDisappear`). Appearances are applied first, so when a top
/// disappears the batch's appearances are already on screen.
///
/// - **On screen.** Every entry is on screen from its `onAppear` until its
///   `onDisappear`. Activity is appearances only: each applied appearance
///   (a push, a pop by reappearance, or a top shown again) stamps its
///   navigator and every ancestor; a pop caused by a disappearance stamps
///   nothing.
/// - **Top disappearance on the root:** always a `pop` to the entry below,
///   if any, as before nested navigators existed (the root's facts are
///   unchanged).
/// - **Top disappearance on a nested navigator:**
///   - the revealed entry is on screen: a `pop` (a stackless sheet's
///     dismissal, a back gesture whose reveal already reappeared);
///   - the revealed entry is off screen, or there is none, and the
///     navigator is covered: nothing changes and nothing is sent. It is
///     covered when its host route, or one above it, is on its parent's
///     stack but not on top (a push covered the host), or when a sibling
///     navigator (same parent) has a top on screen (a tab switch: the
///     hidden tab keeps its stack);
///   - otherwise it is a teardown (a sheet with its own stack dismissed
///     from any depth): the stack is cleared, nothing is sent, and the
///     navigator is forgotten.
/// - **Rebuild.** A new entry appearing on a nested navigator whose top is
///   off screen restarts that stack: the entry is its first route (no
///   `departing`, `transitionMs` 0), as when a covered navigator's content
///   is replaced. A collapsed split view's detail stack therefore never
///   grows per select and back.
/// - **Forgetting.** A nested navigator is dropped, with no fact, once its
///   host route left the parent's stack (after it was seen there), once its
///   parent is dropped, or once its stack is empty with no navigator below.
/// - **Visible chain.** From the root, through the child (hosted by the
///   top route, or with no host) that has a top on screen, the most
///   recently appeared one where several do. A child with no host is taken
///   over its parent's own on-screen top only when its appearance is
///   newer. `visibleChain()` lists the non-empty stacks in seed order:
///   navigators hosted by covered routes in stack order (Android
///   `sessionStartSnapshots`), then the other children, then the stack
///   itself, then the visible child; the last one's top is the visible
///   route.
struct NavigatorTree {
  /// One navigator. Its stack knows its id and parent.
  struct Node {
    var stack: ScreenStack
    let hostRouteInstanceId: String?
    /// True once the host route was seen on the parent's stack; only then
    /// can it leave (a host may arrive a frame after its children).
    var hostSeen = false
    /// The last appearance applied to this stack.
    var ownAppearance: Int64 = 0
    /// The last appearance applied to this stack or one below it.
    var lastAppearance: Int64 = 0

    init(navigatorId: String, parentNavigatorId: String?, hostRouteInstanceId: String?) {
      stack = ScreenStack(navigatorId: navigatorId, parentNavigatorId: parentNavigatorId)
      self.hostRouteInstanceId = hostRouteInstanceId
    }

    var parentNavigatorId: String? {
      stack.parentNavigatorId
    }
  }

  static let rootId = NavigatorScope.rootNavigatorId

  private(set) var nodes: [String: Node] = [
    NavigatorTree.rootId: Node(navigatorId: NavigatorTree.rootId, parentNavigatorId: nil, hostRouteInstanceId: nil),
  ]
  /// The instance ids whose last callback was `onAppear`.
  private(set) var onScreen: Set<String> = []
  private var appearances: Int64 = 0

  /// The known navigators, sorted.
  var ids: [String] {
    nodes.keys.sorted()
  }

  func entries(of navigatorId: String) -> [RouteEntry]? {
    nodes[navigatorId]?.stack.entries
  }

  /// `navigatorId` and its ancestors, nearest first; one bounded walk.
  func ancestors(of navigatorId: String) -> [String] {
    var out: [String] = []
    var next: String? = navigatorId
    while let id = next, out.count <= nodes.count, let node = nodes[id] {
      out.append(id)
      next = node.parentNavigatorId
    }
    return out
  }

  /// The navigators whose parent is `navigatorId`, sorted.
  func children(of navigatorId: String) -> [String] {
    nodes.filter { $0.value.parentNavigatorId == navigatorId }.map { $0.key }.sorted()
  }

  /// Makes every navigator around `scope` known. A known navigator keeps
  /// the parent and host it was first seen with, as the engine keeps the
  /// first parent it learns.
  mutating func register(_ scope: NavigatorScope) {
    for level in scope.levels where nodes[level.navigatorId] == nil {
      nodes[level.navigatorId] = Node(
        navigatorId: level.navigatorId,
        parentNavigatorId: level.parentNavigatorId,
        hostRouteInstanceId: level.hostRouteInstanceId
      )
    }
  }

  mutating func appeared(_ entry: RouteEntry, on navigatorId: String) -> NavigationChange? {
    guard var node = nodes[navigatorId] else { return nil }
    if navigatorId != NavigatorTree.rootId, !node.stack.contains(instanceId: entry.instanceId),
      let top = node.stack.top, !onScreen.contains(top.instanceId) {
      // Rebuild: the new entry is the first route of a restarted stack.
      node.stack.removeAll()
    }
    let change = node.stack.appeared(entry)
    onScreen.insert(entry.instanceId)
    appearances += 1
    node.ownAppearance = appearances
    nodes[navigatorId] = node
    for id in ancestors(of: navigatorId) {
      nodes[id]?.lastAppearance = appearances
    }
    return change
  }

  /// A screen disappeared, after the batch's appearances.
  mutating func disappeared(instanceId: String) -> NavigationChange? {
    onScreen.remove(instanceId)
    // Only a top route's disappearance changes a stack.
    guard
      let id = nodes.first(where: { $0.value.stack.top?.instanceId == instanceId })?.key,
      var node = nodes[id]
    else { return nil }
    if id != NavigatorTree.rootId {
      let revealed = node.stack.entries.dropLast().last
      guard let shown = revealed, onScreen.contains(shown.instanceId) else {
        if !isCovered(id) {
          // Teardown: prune forgets the emptied navigator.
          node.stack.removeAll()
          nodes[id] = node
        }
        return nil
      }
    }
    let change = node.stack.disappeared(instanceId: instanceId)
    nodes[id] = node
    return change
  }

  /// Whether `navigatorId`, or a navigator above it, has a covered host
  /// route or a sibling with a top on screen (see the type's rules).
  func isCovered(_ navigatorId: String) -> Bool {
    for id in ancestors(of: navigatorId) {
      guard let node = nodes[id], let parentId = node.parentNavigatorId, let parent = nodes[parentId] else { continue }
      if let host = node.hostRouteInstanceId, parent.stack.contains(instanceId: host), parent.stack.top?.instanceId != host {
        return true
      }
      if children(of: parentId).contains(where: { $0 != id && hasTopOnScreen($0) }) {
        return true
      }
    }
    return false
  }

  /// Drops the navigators that left, and the on-screen marks of entries no
  /// stack holds; runs to a fixpoint.
  mutating func prune() {
    for (id, node) in nodes where !node.hostSeen && isHostOnParent(node) {
      nodes[id]?.hostSeen = true
    }
    var dropped = true
    while dropped {
      dropped = false
      for (id, node) in nodes where id != NavigatorTree.rootId && hasLeft(id, node) {
        nodes[id] = nil
        dropped = true
      }
    }
    let held = Set(nodes.values.flatMap { $0.stack.entries.map { $0.instanceId } })
    onScreen.formIntersection(held)
  }

  /// The non-empty stacks in seed order; the last one is the visible
  /// chain's end.
  func visibleChain() -> [ScreenStack] {
    var out: [ScreenStack] = []
    var visited: Set<String> = []
    visit(NavigatorTree.rootId, into: &out, visited: &visited)
    return out
  }

  /// `navigatorId`'s top, or the top of a navigator below it, is on screen.
  private func hasTopOnScreen(_ navigatorId: String) -> Bool {
    nodes.contains { key, node in
      guard let top = node.stack.top, onScreen.contains(top.instanceId) else { return false }
      return ancestors(of: key).contains(navigatorId)
    }
  }

  private func hasLeft(_ id: String, _ node: Node) -> Bool {
    guard let parent = node.parentNavigatorId, nodes[parent] != nil else { return true }
    if node.hostSeen, node.hostRouteInstanceId != nil, !isHostOnParent(node) {
      return true
    }
    return node.stack.entries.isEmpty && !nodes.values.contains { $0.parentNavigatorId == id }
  }

  private func isHostOnParent(_ node: Node) -> Bool {
    guard let host = node.hostRouteInstanceId, let parent = node.parentNavigatorId else { return false }
    return nodes[parent]?.stack.contains(instanceId: host) ?? false
  }

  private func visit(_ id: String, into out: inout [ScreenStack], visited: inout Set<String>) {
    guard let node = nodes[id], visited.insert(id).inserted else { return }
    let top = node.stack.top?.instanceId
    let kids = children(of: id).compactMap { key in nodes[key].map { (key: key, node: $0) } }
    // Navigators hosted by covered routes, in stack order.
    for entry in node.stack.entries where entry.instanceId != top {
      for kid in kids where kid.node.hostRouteInstanceId == entry.instanceId {
        visit(kid.key, into: &out, visited: &visited)
      }
    }
    let uncovered = kids.filter { kid in
      kid.node.hostRouteInstanceId == nil || (top != nil && kid.node.hostRouteInstanceId == top)
    }
    let byAppearance: ((key: String, node: Node), (key: String, node: Node)) -> Bool = {
      ($0.node.lastAppearance, $0.key) < ($1.node.lastAppearance, $1.key)
    }
    let ownOnScreen = top.map { onScreen.contains($0) } ?? false
    let visible = uncovered
      .filter { hasTopOnScreen($0.key) }
      .max(by: byAppearance)
      .flatMap { kid in
        kid.node.hostRouteInstanceId != nil || !ownOnScreen || kid.node.lastAppearance > node.ownAppearance ? kid.key : nil
      }
    let others = uncovered.filter { $0.key != visible }.sorted(by: byAppearance)
    others.forEach { visit($0.key, into: &out, visited: &visited) }
    if !node.stack.entries.isEmpty {
      out.append(node.stack)
    }
    if let visible = visible {
      visit(visible, into: &out, visited: &visited)
    }
  }
}

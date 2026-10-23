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
/// - **Keys and ids.** Navigators are keyed by their `NavigatorScope` id
///   (`swiftui-screens/<name>`). The id sent to the engine is the key for
///   a name's first incarnation in the session and `<key>#<n>` (n = 2, 3,
///   …) for each later one, after the previous one was forgotten, so the
///   engine starts a fresh stack (as Android ids its nested navigators per
///   host instance). Children name their parent's current id.
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
///     navigator (same parent) has a top on screen that appeared more
///     recently than anything in this navigator (a tab switch: the hidden
///     tab keeps its stack);
///   - otherwise it is a teardown (a sheet with its own stack dismissed
///     from any depth): the stack is cleared, nothing is sent, and the
///     navigator is forgotten; the name's next use is a new incarnation.
/// - **Forgetting.** A nested navigator is dropped, with no fact, once its
///   host route left the parent's stack (after it was seen there), once its
///   parent is dropped, or once its stack is empty with no navigator below.
/// - **Visible chain.** From the root, through the child (hosted by the
///   top route, or with no host) that has a top on screen, the most
///   recently appeared one where several do; a child with no host only
///   outranks its parent's own on-screen top when it appeared later.
///   `visibleChain()` lists the non-empty stacks in seed order: navigators
///   hosted by covered routes in stack order (Android
///   `sessionStartSnapshots`), then the other children, then the stack
///   itself, then the visible child; the last one's top is the visible
///   route.
struct NavigatorTree {
  /// One navigator. Its stack knows its engine id and its parent's.
  struct Node {
    var stack: ScreenStack
    /// The parent's key; nil on the root.
    let parentKey: String?
    let hostRouteInstanceId: String?
    /// True once the host route was seen on the parent's stack; only then
    /// can it leave (a host may arrive a frame after its children).
    var hostSeen = false
    /// The last appearance applied to this stack.
    var ownAppearance: Int64 = 0
    /// The last appearance applied to this stack or one below it.
    var lastAppearance: Int64 = 0

    init(navigatorId: String, parentKey: String?, parentNavigatorId: String?, hostRouteInstanceId: String?) {
      stack = ScreenStack(navigatorId: navigatorId, parentNavigatorId: parentNavigatorId)
      self.parentKey = parentKey
      self.hostRouteInstanceId = hostRouteInstanceId
    }
  }

  static let rootId = NavigatorScope.rootNavigatorId

  private(set) var nodes: [String: Node] = [
    NavigatorTree.rootId: Node(navigatorId: NavigatorTree.rootId, parentKey: nil, parentNavigatorId: nil, hostRouteInstanceId: nil),
  ]
  /// The instance ids whose last callback was `onAppear`.
  private(set) var onScreen: Set<String> = []
  /// Incarnations per key in this session.
  private var incarnations: [String: Int] = [:]
  private var appearances: Int64 = 0

  /// The known navigators' keys, sorted.
  var ids: [String] {
    nodes.keys.sorted()
  }

  func entries(of key: String) -> [RouteEntry]? {
    nodes[key]?.stack.entries
  }

  /// The id sent to the engine for the navigator `key`.
  func navigatorId(of key: String) -> String? {
    nodes[key]?.stack.navigatorId
  }

  /// `key` and its ancestors' keys, nearest first; one bounded walk.
  func ancestors(of key: String) -> [String] {
    var out: [String] = []
    var next: String? = key
    while let id = next, out.count <= nodes.count, let node = nodes[id] {
      out.append(id)
      next = node.parentKey
    }
    return out
  }

  /// The keys of the navigators whose parent is `key`, sorted.
  func children(of key: String) -> [String] {
    nodes.filter { $0.value.parentKey == key }.map { $0.key }.sorted()
  }

  /// A new session: the next incarnation of every name is its first again.
  /// Live navigators keep their ids.
  mutating func resetIncarnations() {
    incarnations.removeAll()
  }

  /// Makes every navigator around `scope` known. A known navigator keeps
  /// the parent and host it was first seen with, as the engine keeps the
  /// first parent it learns.
  mutating func register(_ scope: NavigatorScope) {
    for level in scope.levels where nodes[level.navigatorId] == nil {
      let key = level.navigatorId
      let incarnation = (incarnations[key] ?? 0) + 1
      incarnations[key] = incarnation
      nodes[key] = Node(
        navigatorId: incarnation == 1 ? key : "\(key)#\(incarnation)",
        parentKey: level.parentNavigatorId,
        parentNavigatorId: nodes[level.parentNavigatorId]?.stack.navigatorId ?? level.parentNavigatorId,
        hostRouteInstanceId: level.hostRouteInstanceId
      )
    }
  }

  mutating func appeared(_ entry: RouteEntry, on key: String) -> NavigationChange? {
    guard var node = nodes[key] else { return nil }
    let change = node.stack.appeared(entry)
    onScreen.insert(entry.instanceId)
    appearances += 1
    node.ownAppearance = appearances
    nodes[key] = node
    for id in ancestors(of: key) {
      nodes[id]?.lastAppearance = appearances
    }
    return change
  }

  /// A screen disappeared, after the batch's appearances.
  mutating func disappeared(instanceId: String) -> NavigationChange? {
    onScreen.remove(instanceId)
    // Only a top route's disappearance changes a stack.
    guard
      let key = nodes.first(where: { $0.value.stack.top?.instanceId == instanceId })?.key,
      var node = nodes[key]
    else { return nil }
    if key != NavigatorTree.rootId {
      let revealed = node.stack.entries.dropLast().last
      guard let shown = revealed, onScreen.contains(shown.instanceId) else {
        if !isCovered(key) {
          // Teardown: prune forgets the emptied navigator.
          node.stack.removeAll()
          nodes[key] = node
        }
        return nil
      }
    }
    let change = node.stack.disappeared(instanceId: instanceId)
    nodes[key] = node
    return change
  }

  /// Drops the navigators that left, and the on-screen marks of entries no
  /// stack holds; runs to a fixpoint.
  mutating func prune() {
    for (key, node) in nodes where !node.hostSeen && isHostOnParent(node) {
      nodes[key]?.hostSeen = true
    }
    var dropped = true
    while dropped {
      dropped = false
      for (key, node) in nodes where key != NavigatorTree.rootId && hasLeft(key, node) {
        nodes[key] = nil
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

  /// Whether `key`, or a navigator above it, has a covered host route or a
  /// more recently appeared sibling with a top on screen.
  private func isCovered(_ key: String) -> Bool {
    for id in ancestors(of: key) {
      guard let node = nodes[id], let parentKey = node.parentKey, let parent = nodes[parentKey] else { continue }
      if let host = node.hostRouteInstanceId, parent.stack.contains(instanceId: host), parent.stack.top?.instanceId != host {
        return true
      }
      let newerSiblingOnScreen = children(of: parentKey).contains { sibling in
        sibling != id && hasTopOnScreen(sibling) && (nodes[sibling]?.lastAppearance ?? 0) > node.lastAppearance
      }
      if newerSiblingOnScreen {
        return true
      }
    }
    return false
  }

  /// `key`'s top, or the top of a navigator below it, is on screen.
  private func hasTopOnScreen(_ key: String) -> Bool {
    nodes.contains { other, node in
      guard let top = node.stack.top, onScreen.contains(top.instanceId) else { return false }
      return ancestors(of: other).contains(key)
    }
  }

  private func hasLeft(_ key: String, _ node: Node) -> Bool {
    guard let parent = node.parentKey, nodes[parent] != nil else { return true }
    if node.hostSeen, node.hostRouteInstanceId != nil, !isHostOnParent(node) {
      return true
    }
    return node.stack.entries.isEmpty && !nodes.values.contains { $0.parentKey == key }
  }

  private func isHostOnParent(_ node: Node) -> Bool {
    guard let host = node.hostRouteInstanceId, let parent = node.parentKey else { return false }
    return nodes[parent]?.stack.contains(instanceId: host) ?? false
  }

  /// A child hosted by the top route always outranks its parent's own top
  /// (it is drawn inside it); a child with no host only when the parent's
  /// own top is off screen or it appeared later.
  private func outranksOwnTop(_ kid: Node, of node: Node) -> Bool {
    guard kid.hostRouteInstanceId == nil else { return true }
    let ownOnScreen = node.stack.top.map { onScreen.contains($0.instanceId) } ?? false
    return !ownOnScreen || kid.lastAppearance > node.ownAppearance
  }

  private func visit(_ key: String, into out: inout [ScreenStack], visited: inout Set<String>) {
    guard let node = nodes[key], visited.insert(key).inserted else { return }
    let top = node.stack.top?.instanceId
    let kids = children(of: key).compactMap { child in nodes[child].map { (key: child, node: $0) } }
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
    // Select, then order, then recurse.
    let newest = uncovered.filter { hasTopOnScreen($0.key) }.max(by: byAppearance)
    let visible = newest.flatMap { outranksOwnTop($0.node, of: node) ? $0.key : nil }
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

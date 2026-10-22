/// The adapter's model of one navigator's stack (bottom first), built from
/// appear and disappear callbacks. It exists to tell push and pop apart;
/// the engine keeps its own stacks.
///
/// - A route that appears on top of the stack is a `push` covering the
///   previous top.
/// - A route that appears while already below the top was revealed: a `pop`
///   to it, and everything above it leaves.
/// - The top route disappearing is a `pop` to the route below, if any.
/// - A covered route disappearing changes nothing (it may reappear).
struct ScreenStack {
  static let maxEntries = 64

  let navigatorId: String
  private(set) var entries: [RouteEntry] = []

  init(navigatorId: String) {
    self.navigatorId = navigatorId
  }

  var top: RouteEntry? {
    entries.last
  }

  mutating func appeared(_ entry: RouteEntry) -> NavigationChange? {
    if let index = entries.firstIndex(where: { $0.instanceId == entry.instanceId }) {
      guard index < entries.count - 1 else { return nil }
      let departing = top
      entries.removeSubrange((index + 1)...)
      return change(.pop, route: entry, departing: departing)
    }
    let departing = top
    entries.append(entry)
    if entries.count > ScreenStack.maxEntries {
      entries.removeFirst(entries.count - ScreenStack.maxEntries)
    }
    return change(.push, route: entry, departing: departing)
  }

  mutating func disappeared(instanceId: String) -> NavigationChange? {
    guard let top = top, top.instanceId == instanceId else { return nil }
    entries.removeLast()
    guard let revealed = entries.last else { return nil }
    return change(.pop, route: revealed, departing: top)
  }

  mutating func removeAll() {
    entries.removeAll()
  }

  private func change(_ kind: NavigationKind, route: RouteEntry, departing: RouteEntry?) -> NavigationChange {
    NavigationChange(kind: kind, navigatorId: navigatorId, route: route, departing: departing)
  }
}

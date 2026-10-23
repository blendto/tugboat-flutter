/// Engine `navigation.kind` values for stack transitions. SwiftUI exposes no
/// replacement or invisible removal, so `replace` and `remove` are never
/// sent; `session_start` is its own payload (`NavigationChange.Payload`).
enum NavigationKind: String {
  case push
  case pop
}

/// One stack change, as the engine's navigation fact (stateful-engine.md
/// 8.1): `{kind, navigatorId, parentNavigatorId?, route: {instanceId, name?,
/// type, overlayKind, transitionMs}, departing?: {instanceId, name?, type}}`,
/// or the session start seed `{kind: session_start, navigatorId,
/// parentNavigatorId?, routes: [route, …]}` (Android `NavigationFact.kt`).
///
/// As in Flutter's `NavigatorObserver` mapping, `route` is the route visible
/// after the change (for `pop`, the one revealed) and `departing` the one
/// leaving or covered. `parentNavigatorId` is sent only by a nested
/// navigator (`.tugboatNavigator`), on transitions and seeds alike; the root
/// navigator's facts are unchanged. `overlayKind` is the route's
/// (`.tugboatScreen(_:presentation:)`, `page` by default). `transitionMs` is
/// UIKit's 350 ms navigation transition when a route is covered or
/// revealed, 0 for the first route and for every seeded route, so the
/// engine's route capture waits for the animation.
struct NavigationChange: Equatable {
  static let transitionMs: Int64 = 350

  /// A transition always has a destination route; a seed always has a stack.
  enum Payload: Equatable {
    case transition(NavigationKind, route: RouteEntry, departing: RouteEntry?)
    case sessionStart(routes: [RouteEntry])
  }

  let navigatorId: String
  /// The enclosing navigator of a nested one; nil on a root navigator.
  let parentNavigatorId: String?
  let payload: Payload

  init(kind: NavigationKind, navigatorId: String, parentNavigatorId: String? = nil, route: RouteEntry, departing: RouteEntry?) {
    self.navigatorId = navigatorId
    self.parentNavigatorId = parentNavigatorId
    self.payload = .transition(kind, route: route, departing: departing)
  }

  init(sessionStart navigatorId: String, parentNavigatorId: String? = nil, routes: [RouteEntry]) {
    self.navigatorId = navigatorId
    self.parentNavigatorId = parentNavigatorId
    self.payload = .sessionStart(routes: routes)
  }

  func fact(at: HostTime) -> AdapterFact {
    var input = JSONObject()
    switch payload {
    case let .transition(kind, route, departing):
      input.set("kind", kind.rawValue)
      setNavigator(&input)
      input.set("route", NavigationChange.routeJSON(route, transitionMs: departing == nil ? 0 : NavigationChange.transitionMs))
      if let departing = departing {
        input.set("departing", NavigationChange.entryJSON(departing))
      }
    case let .sessionStart(routes):
      input.set("kind", "session_start")
      setNavigator(&input)
      input.set("routes", .array(routes.map { .object(NavigationChange.routeJSON($0, transitionMs: 0)) }))
    }
    return AdapterFact(type: FactTypes.navigation, input: input, at: at)
  }

  private func setNavigator(_ input: inout JSONObject) {
    input.set("navigatorId", navigatorId)
    if let parent = parentNavigatorId {
      input.set("parentNavigatorId", parent)
    }
  }

  private static func routeJSON(_ entry: RouteEntry, transitionMs: Int64) -> JSONObject {
    var out = entryJSON(entry)
    out.set("overlayKind", entry.overlayKind.rawValue)
    out.set("transitionMs", transitionMs)
    return out
  }

  private static func entryJSON(_ entry: RouteEntry) -> JSONObject {
    var out = JSONObject()
    out.set("instanceId", entry.instanceId)
    if let name = entry.name {
      out.set("name", name)
    }
    out.set("type", entry.type)
    return out
  }
}

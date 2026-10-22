/// Engine `navigation.kind` values the adapter produces. SwiftUI exposes no
/// replacement or invisible removal, so `replace` and `remove` are never
/// sent.
enum NavigationKind: String {
  case push
  case pop
  case sessionStart = "session_start"
}

/// One stack change, as the engine's navigation fact (stateful-engine.md
/// 8.1): `{kind, navigatorId, route: {instanceId, name?, type, overlayKind,
/// transitionMs}, departing?: {instanceId, name?, type}}`.
///
/// As in Flutter's `NavigatorObserver` mapping, `route` is the route visible
/// after the change (for `pop`, the one revealed) and `departing` the one
/// leaving or covered. `overlayKind` is always `page`: a screen cannot tell
/// whether it is presented as a sheet. `transitionMs` is UIKit's 350 ms
/// navigation transition when a route is covered or revealed, 0 for the
/// first route, so the engine's route capture waits for the animation.
struct NavigationChange: Equatable {
  static let transitionMs: Int64 = 350

  let kind: NavigationKind
  let navigatorId: String
  let route: RouteEntry?
  let departing: RouteEntry?
  let routes: [RouteEntry]

  init(kind: NavigationKind, navigatorId: String, route: RouteEntry, departing: RouteEntry?) {
    self.kind = kind
    self.navigatorId = navigatorId
    self.route = route
    self.departing = departing
    self.routes = []
  }

  init(sessionStart navigatorId: String, routes: [RouteEntry]) {
    self.kind = .sessionStart
    self.navigatorId = navigatorId
    self.route = nil
    self.departing = nil
    self.routes = routes
  }

  func fact(at: HostTime) -> AdapterFact {
    var input = JSONObject()
    input.set("kind", kind.rawValue)
    input.set("navigatorId", navigatorId)
    if kind == .sessionStart {
      var routesJSON = [JSONObject]()
      for entry in routes {
        var routeJSON = NavigationChange.entryJSON(entry)
        routeJSON.set("overlayKind", "page")
        routeJSON.set("transitionMs", 0)
        routesJSON.append(routeJSON)
      }
      input.set("routes", routesJSON)
    } else {
      guard let route = route else { fatalError("route required for \(kind)") }
      var routeJSON = NavigationChange.entryJSON(route)
      routeJSON.set("overlayKind", "page")
      routeJSON.set("transitionMs", departing == nil ? 0 : NavigationChange.transitionMs)
      input.set("route", routeJSON)
      if let departing = departing {
        input.set("departing", NavigationChange.entryJSON(departing))
      }
    }
    return AdapterFact(type: FactTypes.navigation, input: input, at: at)
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

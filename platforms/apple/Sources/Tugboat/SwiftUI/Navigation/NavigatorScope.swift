/// Where a `.tugboatScreen` sits among the app's navigators. SwiftUI
/// carries it through the environment: `.tugboatNavigator` opens a nested
/// navigator, `.tugboatScreen` reads the scope it is in and hosts the
/// navigators declared inside it.
///
/// - The root navigator is `swiftui-screens`, with no parent.
/// - `.tugboatNavigator(name)` opens navigator `swiftui-screens/<name>`.
///   Its parent is the enclosing navigator. Its host route is the innermost
///   `.tugboatScreen` around it on that parent, or nil when no screen sits
///   between the two navigators.
/// - A name that repeats any enclosing navigator's, or nesting deeper than
///   `maxDepth`, stays on the enclosing navigator: a navigator is never its
///   own ancestor.
struct NavigatorScope: Equatable {
  /// One nested navigator.
  struct Level: Equatable {
    let navigatorId: String
    let parentNavigatorId: String
    let hostRouteInstanceId: String?
  }

  static let maxDepth = 16
  static let root = NavigatorScope(levels: [], hostRouteInstanceId: nil)

  /// The nested navigators around this point, outermost first; empty on
  /// the root navigator.
  let levels: [Level]
  /// The innermost `.tugboatScreen` around this point on `navigatorId`.
  let hostRouteInstanceId: String?

  /// The navigator a screen here belongs to.
  var navigatorId: String {
    levels.last?.navigatorId ?? ScreenTracker.navigatorId
  }

  /// That navigator's parent; nil on the root navigator.
  var parentNavigatorId: String? {
    levels.last?.parentNavigatorId
  }

  static func navigatorId(named name: String) -> String {
    ScreenTracker.navigatorId + "/" + name
  }

  /// The scope inside `.tugboatNavigator(name)`.
  func nested(_ name: String) -> NavigatorScope {
    let id = NavigatorScope.navigatorId(named: name)
    guard !levels.contains(where: { $0.navigatorId == id }), levels.count < NavigatorScope.maxDepth else { return self }
    let level = Level(navigatorId: id, parentNavigatorId: navigatorId, hostRouteInstanceId: hostRouteInstanceId)
    return NavigatorScope(levels: levels + [level], hostRouteInstanceId: nil)
  }

  /// The scope inside the screen `instanceId`.
  func hosted(by instanceId: String) -> NavigatorScope {
    NavigatorScope(levels: levels, hostRouteInstanceId: instanceId)
  }
}

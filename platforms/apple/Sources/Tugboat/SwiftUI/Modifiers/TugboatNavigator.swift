#if canImport(UIKit)
import SwiftUI

extension View {
  /// Marks this view as its own navigator, such as a `NavigationStack` in a
  /// tab or inside a sheet. Every `.tugboatScreen` inside it is a route on
  /// navigator `swiftui-screens/<name>`, nested in the navigator around it
  /// (`parentNavigatorId`), and hosted by the `.tugboatScreen` around it,
  /// if any: the navigator is forgotten once that screen leaves. Without
  /// it, every screen is on the app's root navigator.
  ///
  /// Use a stable name, unique among the navigators shown together, such
  /// as `"cart"`. Apply it inside the screen that hosts it: on a sheet,
  /// `NavigationStack { … }.tugboatNavigator("sheet").tugboatScreen("Sheet",
  /// presentation: .sheet)` keeps the sheet's own screen on the presenting
  /// navigator. A name equal to the enclosing navigator's adds nothing.
  public func tugboatNavigator(_ name: String) -> some View {
    modifier(TugboatNavigatorModifier(name: name))
  }
}

/// Opens a nested navigator for the content's screens.
struct TugboatNavigatorModifier: ViewModifier {
  let name: String

  @Environment(\.tugboatNavigatorScope) private var scope

  func body(content: Content) -> some View {
    content.environment(\.tugboatNavigatorScope, scope.nested(name))
  }
}

private struct TugboatNavigatorScopeKey: EnvironmentKey {
  static let defaultValue = NavigatorScope.root
}

extension EnvironmentValues {
  /// The navigator `.tugboatScreen` reports to; the root navigator by
  /// default.
  var tugboatNavigatorScope: NavigatorScope {
    get { self[TugboatNavigatorScopeKey.self] }
    set { self[TugboatNavigatorScopeKey.self] = newValue }
  }
}
#endif

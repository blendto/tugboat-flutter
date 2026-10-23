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
  /// - A tab switch sends nothing: the hidden tab keeps its stack and route
  ///   keys follow the shown tab. The first navigation after a tab return
  ///   or a stacked sheet's dismissal is not attributed to its tap (no
  ///   cause, no afterFrame).
  /// - On a sheet with its own stack, put the sheet's root screen inside
  ///   the navigator, `.sheet { NavigationStack { Root().tugboatScreen("Sheet",
  ///   presentation: .sheet) }.tugboatNavigator("sheet") }`, so pushes and
  ///   pops inside the sheet stay on one navigator.
  ///
  /// Give every tab its own navigator with a `.tugboatScreen` inside: a tab
  /// with no sibling navigator on screen when you switch away is torn down,
  /// and its next back is reported as a `push`. A sheet's navigator that is
  /// forgotten and opened again is a new navigator for the engine
  /// (`swiftui-screens/<name>#<n>`).
  ///
  /// Sibling navigators (same enclosing navigator) are treated as mutually
  /// exclusive, like tabs: do not put `.tugboatNavigator` on any
  /// `NavigationSplitView` column or on panes shown together. In a
  /// collapsed split view, back from the detail sends nothing and the
  /// detail stack grows (the SDK's and the engine's); with only the detail
  /// opted in, each back is a `push` of the list screen on the root.
  ///
  /// Use a stable name, such as `"cart"`, unique among the navigators that
  /// exist together, covered screens included: a screen that can be pushed
  /// on top of itself must give each instance's navigator its own name. A
  /// name equal to an enclosing navigator's adds nothing.
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

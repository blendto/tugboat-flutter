#if canImport(UIKit)
import SwiftUI

extension View {
  /// Names the screen this view is the root of. Tugboat reports a route
  /// change when it appears or is revealed again, and uses `name` as the
  /// route key of every target inside it. Use a stable name that does not
  /// depend on locale or data, such as `"Checkout"`, on the root view of
  /// each screen (each `NavigationStack` destination, sheet, or tab).
  ///
  /// The screen is a route on the navigator around it: the app's root
  /// navigator, or the innermost `.tugboatNavigator`. Pass
  /// `presentation: .sheet` on a sheet's root screen. Without a navigator
  /// of its own, the sheet is a route on the navigator that presented it,
  /// recorded as presented over the screen below; with one, put the screen
  /// inside it (see `tugboatNavigator(_:)`).
  /// `presentation: .automatic` (the default) is `.page` in this release.
  public func tugboatScreen(_ name: String, presentation: TugboatScreenPresentation = .automatic) -> some View {
    modifier(TugboatScreenModifier(name: name, presentation: presentation))
  }
}

/// Reports appear and disappear to `ScreenTracker` under one stable
/// instance id, on the navigator its environment names, and hosts the
/// navigators declared inside it.
struct TugboatScreenModifier: ViewModifier {
  let name: String
  let presentation: TugboatScreenPresentation
  let tracker: ScreenTracker

  @Environment(\.tugboatNavigatorScope) private var scope
  @State private var instanceId = ScreenTracker.newInstanceId()

  init(name: String, presentation: TugboatScreenPresentation = .automatic, tracker: ScreenTracker = .shared) {
    self.name = name
    self.presentation = presentation
    self.tracker = tracker
  }

  func body(content: Content) -> some View {
    content
      .environment(\.tugboatNavigatorScope, scope.hosted(by: instanceId))
      .onAppear { tracker.appeared(instanceId: instanceId, name: name, overlayKind: presentation.overlayKind, scope: scope) }
      .onDisappear { tracker.disappeared(instanceId: instanceId) }
  }
}
#endif

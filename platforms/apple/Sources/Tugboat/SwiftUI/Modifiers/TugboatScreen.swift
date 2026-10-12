#if canImport(UIKit)
import SwiftUI

extension View {
  /// Names the screen this view is the root of. Tugboat reports a route
  /// change when it appears or is revealed again, and uses `name` as the
  /// route key of every target inside it. Use a stable name that does not
  /// depend on locale or data, such as `"Checkout"`, on the root view of
  /// each screen (each `NavigationStack` destination, sheet, or tab).
  public func tugboatScreen(_ name: String) -> some View {
    modifier(TugboatScreenModifier(name: name))
  }
}

/// Reports appear and disappear to `ScreenTracker` under one stable
/// instance id.
struct TugboatScreenModifier: ViewModifier {
  let name: String
  let tracker: ScreenTracker

  @State private var instanceId = ScreenTracker.newInstanceId()

  init(name: String, tracker: ScreenTracker = .shared) {
    self.name = name
    self.tracker = tracker
  }

  func body(content: Content) -> some View {
    content
      .onAppear { tracker.appeared(instanceId: instanceId, name: name) }
      .onDisappear { tracker.disappeared(instanceId: instanceId) }
  }
}
#endif

#if canImport(UIKit)
import SwiftUI

extension View {
  /// Gives this view a stable Tugboat identity: taps inside it resolve to
  /// `tag` (high confidence) instead of the nearest UIKit role view, which
  /// SwiftUI drawing does not have. Use a name that is unique within the
  /// screen and does not change between builds or locales, such as
  /// `"checkout"`. The tag never contains visible text and does not change
  /// layout, hit-testing, or accessibility.
  public func tugboatTag(_ tag: String) -> some View {
    modifier(TugboatTagModifier(tag: tag))
  }
}

/// Publishes the tagged view's bounds as an anchor preference, resolves it
/// to the `.global` space in an overlay, and keeps `TagRegistry` current
/// while the view is on screen.
struct TugboatTagModifier: ViewModifier {
  let tag: String
  let registry: TagRegistry

  @State private var id = TagRegistry.newId()
  @Environment(\.tugboatScreenInstance) private var screen

  init(tag: String, registry: TagRegistry = .shared) {
    self.tag = tag
    self.registry = registry
  }

  func body(content: Content) -> some View {
    content
      .anchorPreference(key: TugboatTagAnchorKey.self, value: .bounds) { [id: $0] }
      .overlayPreferenceValue(TugboatTagAnchorKey.self) { anchors in
        GeometryReader { proxy in
          TagFrameReporter(
            id: id,
            entry: TagRegistry.Entry(tag: tag, screen: screen, frame: TugboatTagModifier.globalFrame(anchors[id], in: proxy)),
            registry: registry
          )
        }
      }
  }

  /// The anchor's rect in `.global`: the proxy resolves it locally, and the
  /// proxy's own global origin moves it there.
  static func globalFrame(_ anchor: Anchor<CGRect>?, in proxy: GeometryProxy) -> CGRect {
    let origin = proxy.frame(in: .global).origin
    guard let anchor = anchor else { return CGRect(origin: origin, size: proxy.size) }
    return proxy[anchor].offsetBy(dx: origin.x, dy: origin.y)
  }
}

/// Anchors of tagged views by tag registration id; nested tags each keep
/// their own.
struct TugboatTagAnchorKey: PreferenceKey {
  static var defaultValue: [Int64: Anchor<CGRect>] { [:] }

  static func reduce(value: inout [Int64: Anchor<CGRect>], nextValue: () -> [Int64: Anchor<CGRect>]) {
    value.merge(nextValue()) { current, _ in current }
  }
}

/// An invisible, non-interactive view that writes its entry to the registry
/// when it appears or changes, and removes it when it disappears.
private struct TagFrameReporter: View {
  let id: Int64
  let entry: TagRegistry.Entry
  let registry: TagRegistry

  var body: some View {
    Color.clear
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .onAppear { registry.update(id: id, entry: entry) }
      .onChange(of: entry) { registry.update(id: id, entry: $0) }
      .onDisappear { registry.remove(id: id) }
  }
}
#endif

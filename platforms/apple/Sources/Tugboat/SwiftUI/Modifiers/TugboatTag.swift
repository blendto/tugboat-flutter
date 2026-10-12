#if canImport(UIKit)
import SwiftUI
import UIKit

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

/// Places a `TagMarkerView` behind the tagged content, sized to it, and
/// keeps it registered while it is in the view tree.
struct TugboatTagModifier: ViewModifier {
  let tag: String
  let registry: TagRegistry

  init(tag: String, registry: TagRegistry = .shared) {
    self.tag = tag
    self.registry = registry
  }

  func body(content: Content) -> some View {
    content.background(
      TagMarker(tag: tag, registry: registry)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    )
  }
}

/// The representable behind `.tugboatTag`.
struct TagMarker: UIViewRepresentable {
  let tag: String
  let registry: TagRegistry

  func makeUIView(context: Context) -> TagMarkerView {
    let marker = TagMarkerView(frame: .zero)
    marker.tugboatTag = tag
    registry.register(marker)
    return marker
  }

  func updateUIView(_ marker: TagMarkerView, context: Context) {
    marker.tugboatTag = tag
  }

  static func dismantleUIView(_ marker: TagMarkerView, coordinator: ()) {
    marker.registry?.unregister(marker)
  }
}
#endif

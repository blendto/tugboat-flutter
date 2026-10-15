#if canImport(UIKit)
import SwiftUI
import UIKit

extension View {
  /// Gives this view a stable Tugboat identity: taps inside it resolve to
  /// `tag` (high confidence) instead of the nearest UIKit role view, which
  /// SwiftUI drawing does not have. Use a name that is unique within the
  /// screen and does not change between builds or locales, such as
  /// `"checkout"`. The tag never contains visible text and does not change
  /// layout or hit-testing.
  ///
  /// When `accessibility` is true, `tag` is also set as this view's
  /// `accessibilityIdentifier`, so UI tests (XCUITest, Maestro, Appium) and
  /// exploration runs find the control by the same id. It defaults to false
  /// (opt-in) because apps often set their own identifiers for UI tests.
  /// Label, traits and VoiceOver focus are unchanged, and the identifier is
  /// not part of Tugboat identity.
  ///
  /// Enable it on a single control, not on a container: SwiftUI gives every
  /// accessibility element inside a container the container's identifier.
  /// An identifier the app sets on the same view wins over the tag's,
  /// whichever side of `.tugboatTag` it is on. See the sample's
  /// accessibility UI tests for measured results per control.
  public func tugboatTag(_ tag: String, accessibility: Bool = false) -> some View {
    modifier(TugboatTagModifier(tag: tag, accessibility: accessibility))
  }
}

/// Places a `TagMarkerView` behind the tagged content, sized to it, and
/// keeps it registered while it is in the view tree. With `accessibility`,
/// the content (never the marker) also gets `tag` as its identifier.
struct TugboatTagModifier: ViewModifier {
  let tag: String
  let accessibility: Bool
  let registry: TagRegistry

  init(tag: String, accessibility: Bool = false, registry: TagRegistry = .shared) {
    self.tag = tag
    self.accessibility = accessibility
    self.registry = registry
  }

  func body(content: Content) -> some View {
    identified(content).background(
      TagMarker(tag: tag, registry: registry)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    )
  }

  @ViewBuilder
  private func identified(_ content: Content) -> some View {
    if accessibility {
      content.accessibilityIdentifier(tag)
    } else {
      content
    }
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

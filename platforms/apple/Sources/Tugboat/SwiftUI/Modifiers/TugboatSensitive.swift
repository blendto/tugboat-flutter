#if canImport(UIKit)
import SwiftUI
import UIKit

extension View {
  /// Marks this view's frame as always masked in screenshots, at every mask
  /// level. Pixels are redacted; taps and fingerprints are unchanged.
  public func tugboatSensitive() -> some View {
    modifier(TugboatSensitiveModifier())
  }
}

/// Places a `SensitiveMarkerView` behind the content, sized to it, and keeps
/// it registered while it is in the view tree.
struct TugboatSensitiveModifier: ViewModifier {
  let registry: SensitiveRegistry

  init(registry: SensitiveRegistry = .shared) {
    self.registry = registry
  }

  func body(content: Content) -> some View {
    content.background(
      SensitiveMarker(registry: registry)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    )
  }
}

/// The representable behind `.tugboatSensitive`.
struct SensitiveMarker: UIViewRepresentable {
  let registry: SensitiveRegistry

  func makeUIView(context: Context) -> SensitiveMarkerView {
    let marker = SensitiveMarkerView(frame: .zero)
    registry.register(marker)
    return marker
  }

  func updateUIView(_ marker: SensitiveMarkerView, context: Context) {}

  static func dismantleUIView(_ marker: SensitiveMarkerView, coordinator: ()) {
    marker.registry?.unregister(marker)
  }
}
#endif

#if canImport(UIKit)
import SwiftUI
import UIKit

extension View {
  /// Masks this view's frame in every screenshot, at every mask level,
  /// including on the verified layer-allowlist path where plain colour
  /// fills stay visible. Only pixels are masked: taps, canonical paths and
  /// fingerprints are the same with or without it. It does not change
  /// layout or hit-testing.
  ///
  /// The frame is this view's layout frame; drawing that overflows it (a
  /// shadow, an offset overlay) is masked only if something else masks it.
  /// Remove the modifier to stop masking; it has no `false` form.
  public func tugboatSensitive() -> some View {
    modifier(TugboatSensitiveModifier())
  }
}

/// Places a `SensitiveMarkerView` behind the content, sized to it. The mask
/// walk finds it in the view tree; nothing registers it.
struct TugboatSensitiveModifier: ViewModifier {
  func body(content: Content) -> some View {
    content.background(
      SensitiveMarker()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    )
  }
}

/// The representable behind `.tugboatSensitive`.
struct SensitiveMarker: UIViewRepresentable {
  func makeUIView(context: Context) -> SensitiveMarkerView {
    SensitiveMarkerView(frame: .zero)
  }

  func updateUIView(_ marker: SensitiveMarkerView, context: Context) {}
}
#endif

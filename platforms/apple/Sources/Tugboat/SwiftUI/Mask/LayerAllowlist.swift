#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// The SwiftUI layer classes known to draw text and images, per iOS major
/// version (native SDK note section 6.3). Names are compared as exact
/// strings, read-only (`NSStringFromClass`); no private API is called.
///
/// - The drawing layer is a mangled private Swift class that can change
///   between releases, so each major version is verified on its own with
///   the probe on branch `spike/swiftui-a11y-probe` before it is listed.
/// - It is a generic drawing layer that also carries shapes and custom
///   drawing; every one is masked (over-masking is accepted), and it is
///   never read as "text only".
/// - A major version without an entry masks any window that contains a
///   SwiftUI hosting view in full (`MaskFallback.unverifiedLayerAllowlist`).
struct LayerAllowlist: Equatable {
  /// Image layer frames are padded: the probe's image layer was slightly
  /// smaller than its layout frame.
  static let imagePadding: CGFloat = 4

  /// Verified majors. iOS 26.5, probe of 2026-10-11: text IoU 0.99-1.00,
  /// image IoU 0.76.
  static let verified: [Int: LayerAllowlist] = [
    26: LayerAllowlist(
      textClasses: ["_TtC7SwiftUIP33_863CCF9D49B535DAEB1C7D61BEE53B5914CGDrawingLayer"],
      imageClasses: ["SwiftUI.ImageLayer"]
    ),
  ]

  let textClasses: Set<String>
  let imageClasses: Set<String>

  static func forMajor(_ major: Int) -> LayerAllowlist? {
    verified[major]
  }

  static var runningMajor: Int {
    ProcessInfo.processInfo.operatingSystemVersion.majorVersion
  }
}

#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// The SwiftUI layer classes known to draw text, images and shapes, per iOS
/// major version (native SDK note section 6.3), and the SwiftUI-internal
/// platform views masks may walk into. Names are compared as exact strings,
/// read-only (`NSStringFromClass`); no private API is called.
///
/// - The layer classes are mangled private Swift classes that can change
///   between releases, so each major version is verified on its own (the
///   probe on branch `spike/swiftui-a11y-probe`, and CI layer dumps) before
///   it is listed.
/// - The drawing layer also carries custom drawing, and the shape layer also
///   draws non-rectangular shapes; every one is masked (over-masking is
///   accepted), and neither is read as "text only" or "image only".
/// - A major version without an entry masks any window that contains a
///   SwiftUI hosting view in full (`MaskFallback.unverifiedLayerAllowlist`).
struct LayerAllowlist: Equatable {
  /// Image layer frames are padded: the probe's image layer was slightly
  /// smaller than its layout frame. Shape layers carry their exact path
  /// bounds and are not padded.
  static let imagePadding: CGFloat = 4

  /// Verified majors. iOS 26.5: the probe of 2026-10-11 (text IoU
  /// 0.99-1.00, image IoU 0.76) and CI layer dumps of 2026-10-12, which
  /// showed SF Symbols drawn either into an `ImageLayer` or as a vector
  /// `ColorShapeLayer` (a `CAShapeLayer` subclass without contents). Plain
  /// colour fills are contents-less `CALayer`s and stay visible.
  static let verified: [Int: LayerAllowlist] = [
    26: LayerAllowlist(
      major: 26,
      textClasses: ["_TtC7SwiftUIP33_863CCF9D49B535DAEB1C7D61BEE53B5914CGDrawingLayer"],
      imageClasses: ["SwiftUI.ImageLayer"],
      shapeClasses: ["_TtC7SwiftUIP33_E19F490D25D5E0EC8A24903AF958E34115ColorShapeLayer"]
    ),
  ]

  let major: Int
  let textClasses: Set<String>
  let imageClasses: Set<String>
  let shapeClasses: Set<String>

  static func forMajor(_ major: Int) -> LayerAllowlist? {
    verified[major]
  }

  static var runningMajor: Int {
    ProcessInfo.processInfo.operatingSystemVersion.majorVersion
  }

  /// True when masks may walk into the SwiftUI platform view `className`
  /// on this major (`KnownPlatformViews`); otherwise it is a box.
  func walksPlatformView(_ className: String) -> Bool {
    KnownPlatformViews.isVerified(className, major: major)
  }
}

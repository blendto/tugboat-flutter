/// SwiftUI-internal platform-view hosts, by a fragment of their class name
/// (`String(describing:)`), per iOS major version. Every other
/// `PlatformViewHost` is an app representable or unknown and is a fail-closed
/// box. A listed host is walked: what it draws is still masked by class, or
/// fail-closed when unclassified.
///
/// Verified on iOS 26.5 with CI layer dumps (2026-10-12):
/// - `List`: `UIKitPlatformViewHost<ListRepresentable<…>>` around an
///   `UpdateCoalescingCollectionView`;
/// - `TextField`: `UIKitPlatformViewHost<PlatformViewRepresentableAdaptor<PlatformTextFieldAdaptor>>`
///   around a `UITextField`.
enum KnownPlatformViews {
  static let verified: [Int: [String]] = [
    26: ["<ListRepresentable<", "<PlatformTextFieldAdaptor>"],
  ]

  /// Fragments listed for any verified major, for identity (which must not
  /// change with the iOS version).
  private static let all: [String] = Array(Set(verified.values.flatMap { $0 })).sorted()

  static func isInternal(_ className: String) -> Bool {
    all.contains { className.contains($0) }
  }

  /// True when `className` is listed for `major`; masks walk it only then.
  static func isVerified(_ className: String, major: Int) -> Bool {
    (verified[major] ?? []).contains { className.contains($0) }
  }
}

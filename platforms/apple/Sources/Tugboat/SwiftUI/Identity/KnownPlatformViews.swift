import Foundation

/// SwiftUI-internal platform-view hosts, per iOS major version. A
/// `UIKitPlatformViewHost<…>` wraps one representable type; the host is
/// SwiftUI's own (walked by masks, transparent to identity) only when that
/// type is **declared in the SwiftUI module** and its name is verified for
/// the running major. Every other host, including every app
/// `UIViewRepresentable` / `UIViewControllerRepresentable`, is a fail-closed
/// box. A walked host's content is still masked by class, or fail-closed
/// when unclassified.
///
/// The represented type is read from the host's fully qualified type name
/// (`String(reflecting:)`, read-only), after the adaptor wrappers
/// (`PlatformViewRepresentableAdaptor<…>`,
/// `PlatformViewControllerRepresentableAdaptor<…>`): for example
/// `SwiftUI.UIKitPlatformViewHost<SwiftUI.PlatformViewControllerRepresentableAdaptor<SwiftUI.NavigationStackRepresentable>>`
/// represents `SwiftUI.NavigationStackRepresentable`, while an app's
/// `UIKitPlatformViewHost<…Adaptor<MyApp.MapView>>` represents `MyApp.MapView`.
///
/// Verified on iOS 26.5 with CI view dumps (2026-10-12, `ContainerHostTests`
/// prints them as `TBDUMP` lines): `List` (`ListRepresentable`), `TextField`
/// (`PlatformTextFieldAdaptor`), and the containers that wrap whole screens
/// in a view-controller adaptor around a SwiftUI hosting controller:
/// `NavigationStack` (`NavigationStackRepresentable`), `NavigationView`
/// (`BridgedNavigationView`), and `TabView` (`UIKitAdaptableTabView`).
/// Sheets and full-screen covers present a hosting controller directly
/// (no platform-view host), so they need no entry.
enum KnownPlatformViews {
  static let swiftUIModule = "SwiftUI"

  static let verified: [Int: Set<String>] = [
    26: [
      "ListRepresentable",
      "PlatformTextFieldAdaptor",
      "NavigationStackRepresentable",
      "BridgedNavigationView",
      "UIKitAdaptableTabView",
    ],
  ]

  private static let adaptors: Set<String> = [
    "PlatformViewRepresentableAdaptor",
    "PlatformViewControllerRepresentableAdaptor",
  ]

  /// Names listed for any verified major, for identity (which must not
  /// change with the iOS version).
  private static let all: Set<String> = verified.values.reduce(into: Set<String>()) { $0.formUnion($1) }

  /// True when the host named `qualifiedName` wraps a SwiftUI type listed
  /// for any verified major.
  static func isInternal(_ qualifiedName: String) -> Bool {
    guard let type = representedType(ofHost: qualifiedName), type.module == swiftUIModule else { return false }
    return all.contains(type.name)
  }

  /// True when the host wraps a SwiftUI type listed for `major`; masks walk
  /// it only then.
  static func isVerified(_ qualifiedName: String, major: Int) -> Bool {
    guard let type = representedType(ofHost: qualifiedName), type.module == swiftUIModule else { return false }
    return verified[major]?.contains(type.name) ?? false
  }

  /// The represented type of a `…PlatformViewHost<…>`, as its module and
  /// unqualified name; nil when `qualifiedName` is not a generic host.
  static func representedType(ofHost qualifiedName: String) -> (module: String, name: String)? {
    guard let hostEnd = qualifiedName.range(of: "PlatformViewHost<") else { return nil }
    var current = firstArgument(String(qualifiedName[hostEnd.upperBound...]))
    for _ in 0..<4 {
      let head = TypeName(current)
      guard adaptors.contains(head.name), let inner = head.arguments else { return head.parts }
      current = firstArgument(inner)
    }
    return nil
  }

  /// The first top-level generic argument of `arguments` (the text after an
  /// opening `<`).
  private static func firstArgument(_ arguments: String) -> String {
    var depth = 0
    var out = ""
    for character in arguments {
      if character == "<" { depth += 1 }
      if character == ">" || character == "," {
        if depth == 0 { break }
        if character == ">" { depth -= 1 }
      }
      out.append(character)
    }
    return out.trimmingCharacters(in: .whitespaces)
  }

  /// One qualified type name: `Module.(context).Name<Arguments>`.
  private struct TypeName {
    let module: String
    let name: String
    /// The text after the first `<`, or nil without generic arguments.
    let arguments: String?

    init(_ text: String) {
      let head: Substring
      if let open = text.firstIndex(of: "<") {
        head = text[..<open]
        arguments = String(text[text.index(after: open)...])
      } else {
        head = Substring(text)
        arguments = nil
      }
      module = head.split(separator: ".").first.map(String.init) ?? ""
      name = head.split(separator: ".").last.map(String.init) ?? ""
    }

    var parts: (module: String, name: String) {
      (module, name)
    }
  }
}

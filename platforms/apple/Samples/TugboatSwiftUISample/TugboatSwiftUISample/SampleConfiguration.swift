import Foundation
import Tugboat

/// The sample's `TugboatConfig`. The collector comes from launch arguments
/// (`-TugboatCollectorURL <url> -TugboatCollectorKey <key>`, which land in
/// the `UserDefaults` argument domain), defaulting to the local collector on
/// the simulator's loopback with the dev key. App fields come from the
/// bundle; the installation id is kept in user defaults.
enum SampleConfiguration {
  static let defaultCollectorURL = "http://127.0.0.1:3000"
  static let defaultCollectorKey = "pmk_blend-app-dev-secret"
  private static let installationIdKey = "TugboatSampleInstallationId"

  /// Nil only when neither the launch argument nor the default is a URL.
  static func tugboat(defaults: UserDefaults = .standard, bundle: Bundle = .main) -> TugboatConfig? {
    let urlText = defaults.string(forKey: "TugboatCollectorURL") ?? defaultCollectorURL
    guard let url = URL(string: urlText) ?? URL(string: defaultCollectorURL) else { return nil }
    let key = defaults.string(forKey: "TugboatCollectorKey") ?? defaultCollectorKey
    return TugboatConfig(
      collector: .init(baseURL: url, apiKey: key),
      app: .init(
        name: info(bundle, "CFBundleDisplayName") ?? "Tugboat Sample",
        version: info(bundle, "CFBundleShortVersionString") ?? "",
        buildNumber: info(bundle, "CFBundleVersion") ?? "",
        appId: bundle.bundleIdentifier ?? "",
        installationId: installationId(defaults)
      ),
      captureFocusChanges: true,
      // The sample relies on `.tugboatScreen` alone (native SDK note 5).
      trackHostingControllers: false
    )
  }

  private static func info(_ bundle: Bundle, _ key: String) -> String? {
    bundle.object(forInfoDictionaryKey: key) as? String
  }

  private static func installationId(_ defaults: UserDefaults) -> String {
    if let existing = defaults.string(forKey: installationIdKey) {
      return existing
    }
    let created = UUID().uuidString
    defaults.set(created, forKey: installationIdKey)
    return created
  }
}

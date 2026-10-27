import Foundation
import Tugboat

/// The sample's `TugboatConfig`. The collector comes from launch arguments
/// (`-TugboatCollectorURL <url> -TugboatCollectorKey <key>`, which land in
/// the `UserDefaults` argument domain), defaulting to the local collector on
/// the simulator's loopback with the dev key. `-TugboatEnabled NO` starts
/// dormant (default `YES`); `-TugboatCaptureDiagnostics YES` turns on
/// `captureDiagnostics`; `-TugboatDurableOutbox YES` turns on
/// `durableOutbox` (a launch without it wipes pending entries). App fields come from the bundle; the installation
/// id is kept in user defaults.
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
      // Tugboat is dormant by default; the sample records from launch so
      // device scripts see a session without calling `Tugboat.activate`.
      enabled: defaults.object(forKey: "TugboatEnabled") == nil ? true : defaults.bool(forKey: "TugboatEnabled"),
      captureFocusChanges: true,
      captureDiagnostics: defaults.bool(forKey: "TugboatCaptureDiagnostics"),
      // The sample relies on `.tugboatScreen` alone (native SDK note 5).
      trackHostingControllers: false,
      durableOutbox: defaults.bool(forKey: "TugboatDurableOutbox")
    )
  }

  /// `-TugboatActivationRequestId <id>`: activates at launch with that id.
  static func activationRequestId(defaults: UserDefaults = .standard) -> String? {
    defaults.string(forKey: "TugboatActivationRequestId")
  }

  /// `tugboat-sample://activate?id=<id>`, `tugboat-sample://deactivate` and
  /// `tugboat-sample://clear-pending` (`xcrun simctl openurl booted …`) drive
  /// activation and `clearPendingData` for device scripts.
  static func handle(_ url: URL) {
    guard url.scheme == "tugboat-sample" else { return }
    switch url.host {
    case "activate":
      let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "id" }?.value ?? ""
      Tugboat.activate(activationRequestId: id)
    case "deactivate":
      Tugboat.deactivate()
    case "clear-pending":
      Tugboat.clearPendingData()
    default:
      break
    }
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

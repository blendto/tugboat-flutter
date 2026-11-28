import Foundation

/// Collector endpoint and the app values every request carries.
struct HostConfig: CustomStringConvertible {
  let collectorBaseURL: String
  let apiKey: String
  let appVersion: String
  let appBuild: String
  let appId: String
  var platform = "ios"
  var sdkVersion = TugboatVersion.current

  /// The Flutter `CollectorHttpSink` default headers, same names and order
  /// as the Android host.
  var collectorHeaders: [(name: String, value: String)] {
    [
      ("X-PMKit-API-Key", apiKey),
      ("X-Tugboat-API-Key", apiKey),
      ("X-Platform", platform),
      ("X-App-Build", appBuild),
      ("X-App-Version", appVersion),
      ("X-App-Id", appId),
      ("X-Sdk-Version", sdkVersion),
    ]
  }

  /// A configured `X-Sdk-Version` (a wrapper's), unless blank or not a valid header value.
  static func sdkVersion(configured: String?) -> String {
    let value = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let valid = !value.isEmpty && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    return valid ? value : TugboatVersion.current
  }

  /// Never prints the API key.
  var description: String {
    "HostConfig(collectorBaseURL: \(collectorBaseURL), appId: \(appId), appVersion: \(appVersion), "
      + "appBuild: \(appBuild), platform: \(platform), sdkVersion: \(sdkVersion))"
  }
}

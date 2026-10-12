import Foundation

/// Collector endpoint and the app values every request carries.
struct HostConfig: CustomStringConvertible {
  /// Version of this native SDK, sent as `X-Sdk-Version`.
  static let currentSDKVersion = "0.1.0"

  let collectorBaseURL: String
  let apiKey: String
  let appVersion: String
  let appBuild: String
  let appId: String
  var platform = "ios"
  var sdkVersion = HostConfig.currentSDKVersion

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

  /// Never prints the API key.
  var description: String {
    "HostConfig(collectorBaseURL: \(collectorBaseURL), appId: \(appId), appVersion: \(appVersion), "
      + "appBuild: \(appBuild), platform: \(platform), sdkVersion: \(sdkVersion))"
  }
}

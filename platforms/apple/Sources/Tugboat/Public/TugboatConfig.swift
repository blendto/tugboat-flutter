import Foundation

/// What `Tugboat.start` needs (native SDK note section 3). Everything not
/// here comes from the session engine's defaults (stateful-engine.md
/// section 6).
public struct TugboatConfig {
  public var collector: Collector
  public var app: App
  /// Only `allTextAndMedia` exists in this release.
  public var maskLevel: MaskLevel
  /// Records `focus_changed` for text-input focus transitions (engine
  /// capability `focusChanges`).
  public var captureFocusChanges: Bool
  /// Reports SwiftUI hosting controllers' appearance as routes until the
  /// first `.tugboatScreen` appears. Installs a one-time method exchange on
  /// `UIViewController` appearance; set false to rely on `.tugboatScreen`
  /// alone.
  public var trackHostingControllers: Bool

  public init(
    collector: Collector,
    app: App,
    maskLevel: MaskLevel = .allTextAndMedia,
    captureFocusChanges: Bool = false,
    trackHostingControllers: Bool = true
  ) {
    self.collector = collector
    self.app = app
    self.maskLevel = maskLevel
    self.captureFocusChanges = captureFocusChanges
    self.trackHostingControllers = trackHostingControllers
  }

  /// The collector the SDK delivers to.
  public struct Collector: CustomStringConvertible {
    /// For example `https://collector.example.com`; request paths are
    /// resolved against it.
    public var baseURL: URL
    public var apiKey: String

    public init(baseURL: URL, apiKey: String) {
      self.baseURL = baseURL
      self.apiKey = apiKey
    }

    /// Never prints the API key.
    public var description: String {
      "Collector(baseURL: \(baseURL.absoluteString))"
    }
  }

  /// The app as the collector files it. Every field is required: the
  /// collector rejects a `session_start` without the version and build
  /// number, so `Tugboat.start` refuses to start (and logs why) when one is
  /// blank.
  public struct App {
    public var name: String
    public var version: String
    public var buildNumber: String
    /// The bundle identifier. Also sent as the `X-App-Id` header.
    public var appId: String
    /// Stable per install; the app owns it (for example a UUID kept in its
    /// user defaults).
    public var installationId: String

    public init(name: String, version: String, buildNumber: String, appId: String, installationId: String) {
      self.name = name
      self.version = version
      self.buildNumber = buildNumber
      self.appId = appId
      self.installationId = installationId
    }
  }

  /// What screenshots mask before they are encoded.
  public enum MaskLevel {
    /// Text (UIKit text views and SwiftUI text layers), media (images), and
    /// fail-closed bounds for content the SDK cannot see into (web views,
    /// representables, renderers); the whole frame when the screen cannot
    /// be enumerated with confidence.
    case allTextAndMedia
  }
}

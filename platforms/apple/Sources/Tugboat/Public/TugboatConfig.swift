import Foundation

/// What `Tugboat.start` needs (native SDK note section 3). Everything not
/// here comes from the session engine's defaults (stateful-engine.md
/// section 6).
public struct TugboatConfig {
  public var collector: Collector
  public var app: App
  /// Whether `Tugboat.start` starts a session at once. Off by default, as
  /// Flutter's `TugboatReplayConfig.enabled`: Tugboat stays dormant (no
  /// engine, observers, method exchange, threads, or network; nothing
  /// recorded; the app unchanged) until `Tugboat.activate`. When true, a
  /// session starts at `start` with no `activationRequestId`. Either way,
  /// `Tugboat.deactivate` turns capture off until the next `activate`.
  public var enabled: Bool
  /// Only `allTextAndMedia` exists in this release.
  public var maskLevel: MaskLevel
  /// Records `focus_changed` for text-input focus transitions (engine
  /// capability `focusChanges`).
  public var captureFocusChanges: Bool
  /// Records bounded `capture_diagnostic` events (engine capability
  /// `captureDiagnostics`), as Flutter's `emitCaptureDiagnostics`.
  public var captureDiagnostics: Bool
  /// Reports SwiftUI hosting controllers' appearance as routes until the
  /// first `.tugboatScreen` appears. Installs a one-time method exchange on
  /// `UIViewController` appearance when the first session starts (never
  /// while dormant); set false to rely on `.tugboatScreen` alone. The
  /// exchange is never undone: after `deactivate` or `stop` it forwards to
  /// the original methods and records nothing.
  public var trackHostingControllers: Bool
  /// Opt-in identity for untagged SwiftUI taps from the in-process
  /// accessibility tree (ADR 0010). Off by default; prefer `.tugboatTag`
  /// (optionally `accessibility: true`) on the controls that matter.
  ///
  /// It only changes taps that would otherwise resolve to
  /// `no_actionable_candidate` or to a list cell or scroll view with no
  /// control under it: the tap gets an `AX<Role>#<k>` path segment (role from
  /// the element's traits) or `AXIdentified#<k>` when the app set an
  /// `accessibilityIdentifier`. Only identifiers, traits and frames are read;
  /// labels and values are never read or sent, and the identifier's value is
  /// never sent. Tagged taps and UIKit control taps are unchanged.
  ///
  /// Pros:
  /// - Identity and control type for untagged SwiftUI controls, with no code
  ///   changes.
  /// - App-set accessibility identifiers become reachable: used as path
  ///   evidence now, and as aliases once a filter for data-derived ids exists.
  ///
  /// Cons, measured on an iPhone 12, iOS 18.6.2, Release build:
  /// - Building the tree stalls the main thread once, for about 85–300 ms. It
  ///   runs on the main queue's next turn after the first qualifying tap
  ///   ends; that tap is reported as with the option off.
  /// - The cost starts at the first tree read and cannot be turned off for
  ///   the rest of the process: LazyVStack scroll main-thread time +104%,
  ///   state updates +55%, process CPU +31%, memory +5 MB; scrolling in the
  ///   TugboatSwiftUISample +27%.
  /// - The host app's `@Environment(\.accessibilityEnabled)` becomes true for
  ///   the rest of the process, so UI that adapts to assistive users adapts
  ///   for everyone in that process.
  /// - It relies on an undocumented UIKit side effect of the public
  ///   `accessibilityActivate()`, which Apple can change.
  /// - `accessibilityHitTest(_:)` stays nil, so a tap is matched to the
  ///   smallest element whose frame contains it.
  /// - A lazy-stack hang with the tree built is documented on iOS 26 (Pendo;
  ///   Apple FB21851974).
  ///
  /// It runs only on iOS majors where it was measured (iOS 18); elsewhere it
  /// behaves as `.off` and logs once. `.sampled(rate:)` is drawn once per
  /// process launch. With `.off` the tree is never built or read, even when
  /// VoiceOver is running. Changing this changes identity: sampled-in
  /// processes give some taps a deeper path and a different fingerprint.
  public var swiftUIAccessibilityIdentity: SwiftUIAccessibilityIdentity
  /// Sent on every `session.start` when non-blank (omitted when nil or
  /// blank), as Flutter's `TugboatReplayConfig.explorationRunId`. The
  /// activation id is not configuration: it comes from `Tugboat.activate`.
  public var explorationRunId: String?
  /// Keeps collector requests the collector has not yet accepted on disk
  /// (`Application Support/Tugboat/outbox/v1/`, excluded from backup, file
  /// protection `completeUntilFirstUserAuthentication`) and sends them again
  /// after the process restarts, while a later session runs. Off by default.
  /// Entries hold only what is already on the wire: masked JPEGs and the
  /// same JSON bodies, never the API key. A `start` with this false deletes
  /// any pending entries; `Tugboat.clearPendingData()` deletes them at any
  /// time. `enabled` false (dormant) keeps them, and nothing is sent while
  /// dormant.
  public var durableOutbox: Bool
  /// Upper bound on the outbox's size on disk, in bytes (default 20 MiB).
  /// Over it, entries from earlier sessions go first, oldest first, frames
  /// before events; lifecycle posts are removed only by age.
  public var outboxMaxBytes: Int
  /// Upper bound on the number of outbox entries (each frame counts one);
  /// default 1000. Evicts as `outboxMaxBytes` does.
  public var outboxMaxEntries: Int
  /// Entries older than this are deleted unsent (default 72 hours).
  public var outboxMaxAgeMs: Int
  /// Sends of one entry, counted across launches, after which it is deleted
  /// unsent (default 8).
  public var outboxMaxAttempts: Int

  public init(
    collector: Collector,
    app: App,
    enabled: Bool = false,
    maskLevel: MaskLevel = .allTextAndMedia,
    captureFocusChanges: Bool = false,
    captureDiagnostics: Bool = false,
    trackHostingControllers: Bool = true,
    swiftUIAccessibilityIdentity: SwiftUIAccessibilityIdentity = .off,
    explorationRunId: String? = nil,
    durableOutbox: Bool = false,
    outboxMaxBytes: Int = 20 * 1024 * 1024,
    outboxMaxEntries: Int = 1000,
    outboxMaxAgeMs: Int = 72 * 60 * 60 * 1000,
    outboxMaxAttempts: Int = 8
  ) {
    self.collector = collector
    self.app = app
    self.enabled = enabled
    self.maskLevel = maskLevel
    self.captureFocusChanges = captureFocusChanges
    self.captureDiagnostics = captureDiagnostics
    self.trackHostingControllers = trackHostingControllers
    self.swiftUIAccessibilityIdentity = swiftUIAccessibilityIdentity
    self.explorationRunId = explorationRunId
    self.durableOutbox = durableOutbox
    self.outboxMaxBytes = outboxMaxBytes
    self.outboxMaxEntries = outboxMaxEntries
    self.outboxMaxAgeMs = outboxMaxAgeMs
    self.outboxMaxAttempts = outboxMaxAttempts
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
  /// number, so `Tugboat.start` refuses the configuration (and logs why)
  /// when one is blank.
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

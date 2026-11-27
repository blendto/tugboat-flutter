import Foundation

/// What an HTTP-client adapter in this repository (`TugboatAlamofire`)
/// needs besides the public network-call API. SPI, not for app code:
/// `@_spi(TugboatAdapters) import Tugboat`.
@_spi(TugboatAdapters)
public enum TugboatAdapters {
  /// Whether a call begun now would be recorded: a session is running and
  /// takes evidence. Adapters check it before running the app's route
  /// resolver, as `tugboat_dio` does.
  public static var isAcceptingEvidence: Bool {
    EvidenceChannel.shared.admit() != nil
  }

  /// `Tugboat.beginNetworkCall(method:route:)`, on every platform.
  public static func beginNetworkCall(method: String, route: String?) -> TugboatNetworkCall {
    TugboatNetworkCall.begin(method: method, route: route, channel: .shared)
  }

  /// The resolver's route, trimmed as Dart's `String.trim`; nil when it
  /// returns nil or an empty route, or throws.
  public static func route(for request: URLRequest, _ resolver: TugboatRouteResolver) -> String? {
    NetworkRoute.resolve(resolver, request)
  }

  /// The error body for `complete(errorResponseBody:)` from the response
  /// bytes (evidence-messages.md section 4.5): only the first 65,537 are
  /// read. JSON text when complete and `contentType` is JSON, otherwise
  /// text; nil when empty.
  public static func errorResponseBody(bytes: Data, contentType: String?) -> Any? {
    HTTPErrorBody.body(bytes: bytes, contentType: contentType)
  }

  /// Tests only: until `close()`, evidence goes to `sink` as the engine
  /// message type and its input JSON (what the engine would receive), on
  /// the main thread, instead of to the running session.
  public static func tapEvidenceForTesting(
    _ sink: @escaping (_ type: String, _ inputJSON: String) -> Void
  ) -> TugboatEvidenceTap {
    let tap = TapSink(sink)
    return TugboatEvidenceTap(restore: EvidenceChannel.shared.tap(tap))
  }
}

/// An open `TugboatAdapters.tapEvidenceForTesting` tap.
@_spi(TugboatAdapters)
public final class TugboatEvidenceTap {
  private let restore: () -> Void

  init(restore: @escaping () -> Void) {
    self.restore = restore
  }

  /// Puts the previous evidence path back.
  public func close() {
    restore()
  }
}

private final class TapSink: EvidenceSink {
  private let sink: (String, String) -> Void

  init(_ sink: @escaping (String, String) -> Void) {
    self.sink = sink
  }

  var isRunning: Bool { true }

  func postEvidence(type: String, inputJSON: String, at: HostTime) {
    sink(type, inputJSON)
  }
}

/// What a view class draws for itself, for a framework whose text and images
/// are not `UILabel` and `UIImageView` (React Native's paragraph and image
/// views): the screenshot masks it whole.
@_spi(TugboatAdapters)
public enum TugboatViewRole {
  case text
  case image
}

#if canImport(UIKit)
import UIKit

/// Seams for the React Native adapter (`@tugboat/react-native`), which draws
/// plain UIKit views and names its own screens. Nothing here changes an app
/// that does not call it. Main thread, except `setScreen`.
@_spi(TugboatAdapters)
extension TugboatAdapters {
  /// Names the current screen, as `.tugboatScreen` does for a SwiftUI one:
  /// an `instanceId` not seen before is a push, one already on the stack is
  /// a pop back to it, and `name` is the route key of every target below.
  /// Any thread; the work runs on the main thread in call order. Kept while
  /// no session runs, so the next session's `session_start` starts from it.
  public static func setScreen(name: String, instanceId: String) {
    let run = {
      ScreenTracker.shared.appeared(instanceId: instanceId, name: name)
    }
    if Thread.isMainThread {
      run()
    } else {
      DispatchQueue.main.async(execute: run)
    }
  }

  /// The app names its own screens with `setScreen` (React Native): the first
  /// screen named in a session is its initial route (`session_start`, with a
  /// frame of its own), as in Flutter, not a push. Off by default. Any thread;
  /// call before `Tugboat.start`.
  public static func setHostNamesScreens(_ enabled: Bool) {
    let run = { ScreenTracker.shared.seedsFirstScreen = enabled }
    if Thread.isMainThread {
      run()
    } else {
      DispatchQueue.main.async(execute: run)
    }
  }

  /// A name for a view that is not a UIKit control (a React Native `testID`,
  /// its `accessibilityIdentifier`): a view with a name is a tap target and a
  /// path segment (`Named#<ordinal>`), and the name is the anchor's tag, so
  /// its `tagFingerprint` is the alias. Nil, or a blank name, changes
  /// nothing; nil clears the provider.
  public static func setViewNameProvider(_ provider: ((UIView) -> String?)?) {
    HostViewSeams.setNameProvider(provider)
  }

  /// The role of a view class that draws its own text or images; nil leaves
  /// the class as the adapter classifies it. Called once per class, so it
  /// must not depend on an instance. Nil clears it.
  public static func setViewRoleClassifier(_ classifier: ((AnyClass) -> TugboatViewRole?)?) {
    HostViewSeams.setRoleClassifier(classifier)
  }

  /// Masks `view`'s frame in every screenshot, as `.tugboatSensitive()`
  /// does, without changing identity. Not undone.
  public static func markSensitive(_ view: UIView) {
    HostViewSeams.markSensitive(view)
  }
}
#endif

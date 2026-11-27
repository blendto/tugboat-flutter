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

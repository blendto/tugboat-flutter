/// Why a network call ended without a usable response
/// (`TugboatNetworkCall.fail`).
public enum TugboatNetworkFailure: Sendable {
  /// The request failed in transport (offline, timeout, TLS, …).
  case networkError
  /// The app or the system cancelled the request.
  case cancelled

  var outcome: String {
    switch self {
    case .networkError: return "network_error"
    case .cancelled: return "cancelled"
    }
  }
}

/// One logical network call, from `Tugboat.beginNetworkCall(method:route:)`
/// to `complete` or `fail`, recorded as `network_call` evidence.
///
/// Only the first `complete` or `fail` counts; later ones are ignored. Each
/// may be called from any thread, and the time is taken on that thread. A
/// call begun while Tugboat was not started, stopped, or disabled, or with
/// an empty route, records nothing, and so does one finished after its
/// session ended. Nothing here throws or traps into the app.
public final class TugboatNetworkCall: @unchecked Sendable {
  private struct Started {
    let channel: EvidenceChannel
    let generation: Int
    let method: String
    let route: String
    let startMonoUs: Int64
  }

  // `started` is immutable; `finished` is lock-guarded.
  private let started: Started?
  private let finished = Locked(false)

  private init(started: Started?) {
    self.started = started
  }

  /// Begins a call at the current time; a no-op token when `route` is nil
  /// or empty or nothing accepts evidence.
  static func begin(method: String, route: String?, channel: EvidenceChannel) -> TugboatNetworkCall {
    let at = channel.now()
    guard let route = route, !route.isEmpty, let generation = channel.admit() else {
      return TugboatNetworkCall(started: nil)
    }
    return TugboatNetworkCall(
      started: Started(
        channel: channel, generation: generation, method: method, route: route, startMonoUs: at.monoUs))
  }

  /// The call got a response with `statusCode`. `errorResponseBody` is kept
  /// (bounded) only for a status of 400 or more: a `String` as text, a
  /// dictionary or array of JSON values as JSON; `Data` and other values
  /// give no body. `attemptCount` counts the tries of one logical call.
  public func complete(statusCode: Int? = nil, attemptCount: Int? = nil, errorResponseBody: Any? = nil) {
    finish(outcome: "response", statusCode: statusCode, attemptCount: attemptCount, errorResponseBody: errorResponseBody)
  }

  /// The call failed in transport or was cancelled. A status code and error
  /// body are kept as in `complete`.
  public func fail(
    _ failure: TugboatNetworkFailure, statusCode: Int? = nil, attemptCount: Int? = nil, errorResponseBody: Any? = nil
  ) {
    finish(
      outcome: failure.outcome, statusCode: statusCode, attemptCount: attemptCount, errorResponseBody: errorResponseBody)
  }

  private func finish(outcome: String, statusCode: Int?, attemptCount: Int?, errorResponseBody: Any?) {
    guard let started = started else { return }
    let at = started.channel.now()
    let first = finished.withLock { (done: inout Bool) -> Bool in
      defer { done = true }
      return !done
    }
    guard first else { return }
    let facts = NetworkCallFacts(
      method: started.method, route: started.route, startMonoUs: started.startMonoUs, endMonoUs: at.monoUs,
      statusCode: statusCode, outcome: outcome, attemptCount: attemptCount, errorResponseBody: errorResponseBody)
    started.channel.submit(
      type: EvidenceMessages.networkCall, inputJSON: EvidenceMessages.networkCallInput(facts), at: at,
      generation: started.generation)
  }
}

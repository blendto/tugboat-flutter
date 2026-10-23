import Foundation

/// An `HTTPSender` that notices when the session's `session_end` lifecycle
/// post settles, so `stop()` can dispose the engine without cutting off its
/// drain (C5): the engine holds `session_end` until frames and events have
/// drained or `endDrainTimeoutMs` passed, and `engine.dispose` starts no
/// new IO. Settled means accepted (202) or dropped for good (a status the
/// engine does not retry); a retried outcome keeps waiting.
///
/// The engine does not say when delivery settled, so this repeats its retry
/// rule (`isFinal`); `StopTests` pins the copy to the engine source and its
/// conformance fixture, as Android's `EngineRetryRuleTest` does.
final class SessionEndWatcher: HTTPSender {
  private struct State {
    var settled = false
    var onSettled: (() -> Void)?
  }

  private let delegate: HTTPSender
  private let state = Locked(State())

  init(delegate: HTTPSender) {
    self.delegate = delegate
  }

  func send(_ request: HTTPRequest, onResult: @escaping (TransportOutcome) -> Void) {
    let sessionEnd = SessionEndWatcher.isSessionEnd(request)
    delegate.send(request) { [weak self] outcome in
      onResult(outcome)
      if sessionEnd, SessionEndWatcher.isFinal(outcome) {
        self?.settle()
      }
    }
  }

  /// Also drops a pending `whenSettled` callback.
  func close() {
    stopWaiting()
    delegate.close()
  }

  /// Drops a pending `whenSettled` callback.
  func stopWaiting() {
    state.withLock { $0.onSettled = nil }
  }

  /// Runs `callback` once `session_end` settles (at once, on this thread,
  /// if it already has); otherwise on the IO queue.
  func whenSettled(_ callback: @escaping () -> Void) {
    let runNow = state.withLock { (state: inout State) -> Bool in
      if state.settled { return true }
      state.onSettled = callback
      return false
    }
    if runNow { callback() }
  }

  private func settle() {
    let callback = state.withLock { (state: inout State) -> (() -> Void)? in
      state.settled = true
      defer { state.onSettled = nil }
      return state.onSettled
    }
    callback?()
  }

  static func isSessionEnd(_ request: HTTPRequest) -> Bool {
    guard request.lane == "lifecycle", case let .json(text) = request.body,
      let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    else {
      return false
    }
    return object["eventType"] as? String == "session_end"
  }

  /// Mirrors the engine's `classify` in `core/session-engine/src/transport.cpp`
  /// (fixture `delivery-status-classification`): 202 is accepted; 408, 429,
  /// 5xx, `error`, and `timeout` are retried; anything else is dropped for
  /// good.
  static func isFinal(_ outcome: TransportOutcome) -> Bool {
    guard case let .http(status, _, _) = outcome else { return false }
    return status != 408 && status != 429 && status < 500
  }
}

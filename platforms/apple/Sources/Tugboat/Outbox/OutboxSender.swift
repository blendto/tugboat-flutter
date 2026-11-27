import Foundation

/// An `HTTPSender` that writes each engine request to the outbox as it
/// sends it (`TugboatConfig.durableOutbox`). The request starts at once, in
/// parallel with the write, so the engine's answer deadline is unaffected;
/// every keyed request carries `Tugboat-Delivery-Key`. `close` lets the
/// writes already queued land before the executor closes, for at most
/// `closeWaitSeconds` (Android's 5 s `CLOSE_WAIT_MS`): a slow or stuck disk
/// cannot hang `stop()`. Writes not landed by then stay queued and land later;
/// like Android, `close` reports nothing and closes the delegate regardless.
final class OutboxSender: HTTPSender {
  /// How long `close` waits for queued writes before closing the delegate.
  static let closeWaitSeconds: TimeInterval = 5

  private let delegate: HTTPSender
  private let outbox: Outbox
  private let context: OutboxContext
  private let frameBytes: (_ handle: String) -> Data?
  private let registration: Outbox.SenderRegistration
  private let closeWaitSeconds: TimeInterval

  /// `frameBytes` reads the JPEG for a frame handle (`FrameHandleTable.get`)
  /// on the engine queue, at dispatch.
  init(
    delegate: HTTPSender, outbox: Outbox, context: OutboxContext,
    frameBytes: @escaping (_ handle: String) -> Data?,
    closeWaitSeconds: TimeInterval = OutboxSender.closeWaitSeconds
  ) {
    self.closeWaitSeconds = closeWaitSeconds
    self.delegate = delegate
    self.outbox = outbox
    self.context = context
    self.frameBytes = frameBytes
    self.registration = outbox.registerSender()
  }

  func send(_ request: HTTPRequest, onResult: @escaping (TransportOutcome) -> Void) {
    let attempt = outbox.record(request, sender: registration, context: context, frameBytes: frameBytes)
    var sent = request
    sent.deliveryKey = attempt?.headerValue
    let outbox = self.outbox
    delegate.send(sent) { outcome in
      if let attempt = attempt {
        outbox.answered(attempt, outcome: outcome)
      }
      onResult(outcome)
    }
  }

  func close() {
    _ = outbox.waitForWrites(timeout: closeWaitSeconds)
    delegate.close()
  }
}

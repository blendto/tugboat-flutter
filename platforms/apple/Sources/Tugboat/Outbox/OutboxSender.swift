import Foundation

/// An `HTTPSender` that writes each engine request to the outbox as it
/// sends it (`TugboatConfig.durableOutbox`). The request starts at once, in
/// parallel with the write, so the engine's answer deadline is unaffected;
/// every keyed request carries `Tugboat-Delivery-Key`. `close` lets the
/// writes already queued land before the executor closes.
final class OutboxSender: HTTPSender {
  private let delegate: HTTPSender
  private let outbox: Outbox
  private let context: OutboxContext
  private let frameBytes: (_ handle: String) -> Data?
  private let registration: Outbox.SenderRegistration

  /// `frameBytes` reads the JPEG for a frame handle (`FrameHandleTable.get`)
  /// on the engine queue, at dispatch.
  init(delegate: HTTPSender, outbox: Outbox, context: OutboxContext, frameBytes: @escaping (_ handle: String) -> Data?) {
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
    outbox.waitForWrites()
    delegate.close()
  }
}

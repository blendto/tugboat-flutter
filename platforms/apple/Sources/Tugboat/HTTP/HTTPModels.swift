import Foundation

/// One collector request from an `http.send` effect.
struct HTTPRequest: Equatable {
  let requestId: String
  let lane: String
  let path: String
  let timeoutMs: Int
  let body: HTTPBody
}

enum HTTPBody: Equatable {
  /// The engine's pre-encoded `jsonBody`, sent byte for byte.
  case json(String)

  /// Form `fields` in engine order, then one `files` part per frame whose
  /// JPEG bytes the host resolves from the frame handle table at send time.
  case multipart(fields: [FormField], frames: [FramePart])
}

struct FormField: Equatable {
  let name: String
  let value: String
}

struct FramePart: Equatable {
  let handle: String
  let filename: String
}

/// What a request came to; becomes the `transport.result` input.
enum TransportOutcome: Equatable {
  /// Any HTTP response. `body` is at most `HTTPExecutor.maxBodyBytes` bytes,
  /// decoded as UTF-8.
  case http(status: Int, body: String)
  case error
  case timeout
}

/// Executes `http.send` effects off the engine queue.
protocol HTTPSender: AnyObject {
  /// Runs `request` asynchronously. `onResult` is called exactly once, from
  /// any queue, whatever fails (a failure becomes `.error`).
  func send(_ request: HTTPRequest, onResult: @escaping (TransportOutcome) -> Void)

  /// Answers requests that have not started with `.error` and stops taking
  /// new ones; requests in flight keep their deadline and answer normally.
  func close()
}

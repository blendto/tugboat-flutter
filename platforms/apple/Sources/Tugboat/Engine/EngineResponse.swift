import Foundation

/// One engine response: the status and a copy of the engine's UTF-8 JSON
/// document (the response on `ok`, an error document otherwise).
struct EngineResponse {
  let status: EngineStatus
  let json: Data

  /// The document as text, for logs.
  var text: String {
    String(decoding: json, as: UTF8.self)
  }
}

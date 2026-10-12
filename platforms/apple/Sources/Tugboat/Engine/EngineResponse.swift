import Foundation
import TugboatSessionEngine

/// One engine response: the C status and a copy of the engine's UTF-8 JSON
/// document (the response on `TB_SESSION_OK`, an error document otherwise).
struct EngineResponse {
  let status: tb_session_status
  let json: Data

  /// The engine's stable lowercase status name, e.g. `invalid_message`.
  var statusName: String {
    String(cString: tb_session_status_name(status))
  }

  /// The document as text, for logs.
  var text: String {
    String(decoding: json, as: UTF8.self)
  }
}

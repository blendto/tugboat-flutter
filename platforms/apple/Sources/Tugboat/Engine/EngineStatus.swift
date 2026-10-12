/// Mirrors `tb_session_status` in `tb_session_engine.h`; the raw value is the
/// C value.
enum EngineStatus: Int {
  case ok = 0
  case invalidArgument = 1
  case abiMismatch = 2
  case malformedMessage = 3
  case invalidMessage = 4
  case unsupportedMessage = 5
  case contractMismatch = 6
  case messageTooLarge = 7
  case busy = 8
  case outOfMemory = 9
  case internalError = 10

  /// Codes this build does not know are treated as `internalError`.
  init(code: Int) {
    self = EngineStatus(rawValue: code) ?? .internalError
  }

  /// The engine's stable lowercase name (`tb_session_status_name`).
  var wireName: String {
    switch self {
    case .ok: return "ok"
    case .invalidArgument: return "invalid_argument"
    case .abiMismatch: return "abi_mismatch"
    case .malformedMessage: return "malformed_message"
    case .invalidMessage: return "invalid_message"
    case .unsupportedMessage: return "unsupported_message"
    case .contractMismatch: return "contract_mismatch"
    case .messageTooLarge: return "message_too_large"
    case .busy: return "busy"
    case .outOfMemory: return "out_of_memory"
    case .internalError: return "internal_error"
    }
  }
}

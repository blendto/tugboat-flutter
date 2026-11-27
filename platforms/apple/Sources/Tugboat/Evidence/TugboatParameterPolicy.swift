/// Which parameter values of a coded event leave the device
/// (`Tugboat.eventHook(source:parameterPolicy:)`). The same modes as the
/// Flutter `TugboatParameterPolicy`.
///
/// The parameter keys are always kept. The session engine applies the
/// policy and the hard limits (depth, key and string lengths, item counts,
/// encoded size) before anything is sent; only a `transform` runs in the app.
public enum TugboatParameterPolicy: Sendable {
  /// Keys only, no values. Use it when the app must not retain values.
  case namesOnly
  /// Values only for these keys; the other values are dropped.
  case allowList(Set<String>)
  /// Calls the closure once for each top-level parameter that can be kept,
  /// on the thread that called `record`, and keeps what it returns (`nil` is
  /// kept as JSON null). Return `TugboatParameterPolicy.drop` to drop the
  /// value; a closure that throws drops it too. Keys are taken in `String <`
  /// order; the closure is not called for keys past the first 64, or for an
  /// empty key or one over 128 UTF-16 units (those are dropped).
  case transform(@Sendable (_ key: String, _ value: Any) throws -> Any?)
  /// Every JSON-safe value within the hard limits (the default). This can
  /// capture feedback text, search terms, ids, and other user content.
  case allowAll

  /// Returned from a `transform` closure to drop a value.
  public static let drop = TugboatParameterDrop()

  /// The engine's `policy.mode`, and the event's `capture.values`.
  var mode: String {
    switch self {
    case .namesOnly: return "names_only"
    case .allowList: return "allow_list"
    case .transform: return "transform"
    case .allowAll: return "allow_all"
    }
  }
}

/// The type of `TugboatParameterPolicy.drop`.
public struct TugboatParameterDrop: Sendable {
  fileprivate init() {}
}

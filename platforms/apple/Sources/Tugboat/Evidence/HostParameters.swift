/// One top-level event parameter as the host hands it to the encoder.
struct HostParameter {
  enum Value {
    /// The app's value (after its `transform`, if any).
    case kept(Any?)
    /// The app's `transform` dropped the value (`TugboatParameterPolicy.drop`
    /// or a throw). The key is still reported.
    case dropped
  }

  let key: String
  let value: Value
}

/// The host's part of a parameter policy: running a `transform`. Every other
/// mode passes the values on unchanged and the engine applies it.
enum HostParameters {
  /// The parameters with keys sorted by `String <` (a Swift dictionary has
  /// no order), each value transformed under `.transform`.
  static func apply(_ policy: TugboatParameterPolicy, to parameters: [String: Any]) -> [HostParameter] {
    let sorted = parameters.sorted { $0.key < $1.key }
    guard case let .transform(transform) = policy else {
      return sorted.map { HostParameter(key: $0.key, value: .kept($0.value)) }
    }
    return sorted.map { HostParameter(key: $0.key, value: run(transform, key: $0.key, value: $0.value)) }
  }

  private static func run(
    _ transform: (String, Any) throws -> Any?, key: String, value: Any
  ) -> HostParameter.Value {
    let result: Any?
    do {
      result = try transform(key, value)
    } catch {
      return .dropped
    }
    return result is TugboatParameterDrop ? .dropped : .kept(result)
  }
}

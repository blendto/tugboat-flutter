/// One top-level event parameter with a valid key, as the host hands it to
/// the encoder (evidence-messages.md sections 4.3, 4.4).
struct HostParameter {
  enum Value {
    /// The app's value, or a `transform`'s result, to encode.
    case kept(Any?)
    /// A `transform` returned `TugboatParameterPolicy.drop` or threw: `{"drop": true}`.
    case dropped
    /// A value the engine never reads (`names_only`, a key outside
    /// `allowedKeys`): sent as `null`, not encoded.
    case unread
  }

  let key: String
  let value: Value
}

/// The top-level parameters map as sent: the first 64 entries (valid keys
/// sorted by `String <`, then one `nonStringKeys` run for invalid keys) and
/// how many entries follow.
struct HostParameterList {
  static let maxEntries = 64

  let entries: [HostParameter]
  /// Invalid keys sent as one `{"nonStringKeys": n}` run after `entries`.
  let invalidKeys: Int
  /// The exact number of entries after the sent ones (`omitted`).
  let omitted: Int
}

/// The host's part of a parameter policy (sections 4.2–4.4). Under
/// `.transform` the closure runs exactly once for each sent entry with a
/// valid key, and never for any other entry. Every other rule of the
/// policy is the engine's.
enum HostParameters {
  /// A key the engine lists: 1 to 128 UTF-16 code units.
  static func isValidKey(_ key: String) -> Bool {
    let units = key.utf16.count
    return units >= 1 && units <= 128
  }

  static func apply(_ policy: TugboatParameterPolicy, to parameters: [String: Any]) -> HostParameterList {
    let valid = parameters.filter { isValidKey($0.key) }.sorted { $0.key < $1.key }
    let sent = valid.prefix(HostParameterList.maxEntries)
    let invalid = parameters.count - valid.count
    let invalidSent = min(invalid, HostParameterList.maxEntries - sent.count)
    let entries = sent.map { HostParameter(key: $0.key, value: value(of: $0, under: policy)) }
    return HostParameterList(
      entries: entries, invalidKeys: invalidSent, omitted: parameters.count - sent.count - invalidSent)
  }

  private static func value(of entry: (key: String, value: Any), under policy: TugboatParameterPolicy) -> HostParameter.Value {
    switch policy {
    case .namesOnly:
      return .unread
    case let .allowList(keys):
      return keys.contains(entry.key) ? .kept(entry.value) : .unread
    case let .transform(transform):
      return run(transform, key: entry.key, value: entry.value)
    case .allowAll:
      return .kept(entry.value)
    }
  }

  private static func run(_ transform: (String, Any) throws -> Any?, key: String, value: Any) -> HostParameter.Value {
    let result: Any?
    do {
      result = try transform(key, value)
    } catch {
      return .dropped
    }
    return ValueKind.isDrop(result) ? .dropped : .kept(result)
  }
}

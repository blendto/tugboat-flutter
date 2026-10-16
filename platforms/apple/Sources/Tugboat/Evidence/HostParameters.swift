/// One top-level event parameter as the host hands it to the encoder
/// (evidence-messages.md section 4.3).
struct HostParameter {
  enum Value {
    /// The app's value, or a `transform`'s result, to encode.
    case kept(Any?)
    /// A `transform` returned `TugboatParameterPolicy.drop` or threw: `{"drop": true}`.
    case dropped
    /// A value the engine never reads (an invalid key, `names_only`, a key
    /// outside `allowedKeys`): sent as `null` (section 4.5).
    case unread
  }

  let key: String
  let value: Value
}

/// The parameters map: its first 64 entries and how many follow.
struct HostParameterList {
  static let maxEntries = 64

  let entries: [HostParameter]
  /// The exact number of entries after `entries` (`omitted`).
  let omitted: Int
}

/// The host's part of a parameter policy (sections 4.2, 4.3, 4.5). Keys are
/// sorted by `String <` (a Swift dictionary has no order) and only the
/// first 64 are sent. Under `.transform` the closure runs exactly once for
/// each of those whose key is valid, and never for any other entry. Every
/// other rule of the policy is the engine's.
enum HostParameters {
  /// A key the engine lists: 1 to 128 UTF-16 code units.
  static func isValidKey(_ key: String) -> Bool {
    let units = key.utf16.count
    return units >= 1 && units <= 128
  }

  static func apply(_ policy: TugboatParameterPolicy, to parameters: [String: Any]) -> HostParameterList {
    let sorted = parameters.sorted { $0.key < $1.key }
    let sent = sorted.prefix(HostParameterList.maxEntries)
    let entries = sent.map { entry in
      HostParameter(key: entry.key, value: isValidKey(entry.key) ? value(of: entry, under: policy) : .unread)
    }
    return HostParameterList(entries: entries, omitted: sorted.count - sent.count)
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

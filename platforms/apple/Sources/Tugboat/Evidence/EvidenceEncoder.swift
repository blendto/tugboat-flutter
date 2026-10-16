import Foundation

/// Writes the app's typed values in the engine's value encoding
/// (core/session-engine/docs/evidence-messages.md section 2), with the host
/// obligations of section 4: Swift types (4.1), keys sorted by `String <`
/// with one `nonStringKeys` run after them (4.2), the required depth bounds
/// (4.4), and the exact elisions of 4.5, so a large value costs little.
/// Every limit and policy rule beyond that is the engine's.
enum EvidenceEncoder {
  /// The `parameters` map value.
  static func parameters(_ list: HostParameterList) -> String {
    var out = "{\"map\":["
    for (index, entry) in list.entries.enumerated() {
      if index > 0 { out += "," }
      out += "[" + JSONText.quoted(entry.key) + "," + parameterValue(entry.value) + "]"
    }
    out += "]"
    if list.omitted > 0 {
      out += ",\"omitted\":\(list.omitted)"
    }
    return out + "}"
  }

  /// `{"value": <encoded>}`, or nil for no body (`nil`, `NSNull`, `Data`).
  /// A string is a text body; anything else is normalized by the engine,
  /// which keeps no body for a root it does not support.
  static func errorResponseBody(_ body: Any) -> String? {
    guard let body = ValueKind.unwrap(body), !ValueKind.isNoBody(body) else {
      return nil
    }
    var writer = ValueWriter(rules: .errorBody)
    if let text = ValueKind.string(body) {
      writer.writeTextBody(text)
    } else {
      writer.write(body, depth: 0)
    }
    return "{\"value\":" + writer.out + "}"
  }

  private static func parameterValue(_ value: HostParameter.Value) -> String {
    switch value {
    case .unread:
      return "null"
    case .dropped:
      return "{\"drop\":true}"
    case let .kept(value):
      var writer = ValueWriter(rules: .parameters)
      writer.write(value, depth: 1)
      return writer.out
    }
  }
}

/// Writes one value. The rules differ between a parameter value (top-level
/// values are depth 1) and an error body (the root is depth 0).
struct ValueWriter {
  enum Rules {
    case parameters
    case errorBody
  }

  /// Parameters: a value at this depth or deeper is unsupported (4.4).
  static let parameterDepthLimit = 5
  /// Parameters: a longer string is unsupported (4.5).
  static let parameterStringUnits = 1024
  /// Parameters: a collection may stop after this many items (4.5).
  static let parameterItemsSent = 257
  /// Error bodies: a collection at this depth or deeper is unsupported (4.4).
  static let errorBodyDepthLimit = 6
  /// Error bodies: items sent per collection before `omitted` (4.5).
  static let errorBodyItemsSent = 128
  /// Error bodies: strings and keys are cut to at least this many units (4.5).
  static let errorBodyStringUnits = 4097
  /// Error bodies: a text body is cut to a prefix longer than this (4.5).
  static let errorBodyTextBytes = 4096
  /// Error bodies: writing stops after this many counted values (4.5).
  static let errorBodyValuesWritten = 4097

  let rules: Rules
  private(set) var out = ""
  /// The collections around the value being written, innermost last: the
  /// instance for a reference type (`NSArray`, `NSDictionary`, `NSSet`),
  /// nil for a Swift value, which cannot be its own ancestor.
  private var ancestors: [ObjectIdentifier?] = []
  /// Error bodies: values written that Dart's encoding counts.
  private var written = 0
  /// Error bodies: open iterables, whose contents are not counted.
  private var openIterables = 0

  init(rules: Rules) {
    self.rules = rules
  }

  private var stopped: Bool {
    rules == .errorBody && written >= ValueWriter.errorBodyValuesWritten
  }

  mutating func write(_ value: Any?, depth: Int) {
    if rules == .parameters && depth >= ValueWriter.parameterDepthLimit {
      out += ValueKind.unsupportedJSON
      return
    }
    switch ValueKind.of(value) {
    case .null:
      emit("null")
    case let .bool(value):
      emit(value ? "true" : "false")
    case let .integer(value):
      emit(String(value))
    case let .double(value):
      emit(ValueKind.doubleJSON(value))
    case let .string(value):
      writeString(value)
    case .unsupported:
      out += ValueKind.unsupportedJSON
    case let .collection(collection, identity):
      writeCollection(collection, identity: identity, depth: depth)
    }
  }

  /// An error body that is a string: cut to a prefix of whole code points
  /// longer than 4096 UTF-8 bytes.
  mutating func writeTextBody(_ text: String) {
    out += JSONText.quoted(ValueWriter.prefix(text, longerThan: ValueWriter.errorBodyTextBytes) { $0.utf8.count })
  }

  /// Writes a value Dart's encoding counts.
  private mutating func emit(_ json: String) {
    countValue()
    out += json
  }

  private mutating func countValue() {
    if openIterables == 0 {
      written += 1
    }
  }

  private mutating func writeString(_ value: String) {
    switch rules {
    case .parameters:
      if value.utf16.count > ValueWriter.parameterStringUnits {
        out += ValueKind.unsupportedJSON
      } else {
        emit(JSONText.quoted(value))
      }
    case .errorBody:
      emit(JSONText.quoted(ValueWriter.errorBodyString(value)))
    }
  }

  private mutating func writeCollection(_ collection: ValueKind.Collection, identity: ObjectIdentifier?, depth: Int) {
    if rules == .errorBody && depth >= ValueWriter.errorBodyDepthLimit {
      out += ValueKind.unsupportedJSON
      return
    }
    if let identity = identity, let index = ancestors.lastIndex(of: identity) {
      out += "{\"ref\":\(ancestors.count - index)}"
      return
    }
    ancestors.append(identity)
    defer { ancestors.removeLast() }
    switch collection {
    case let .list(items):
      countValue()
      writeItems(items, tag: "list", depth: depth)
    case let .iterable(items):
      openIterables += 1
      writeItems(items, tag: "iterable", depth: depth)
      openIterables -= 1
    case let .map(entries, nonStringKeys):
      countValue()
      switch rules {
      case .parameters: writeParameterMap(entries, nonStringKeys: nonStringKeys, depth: depth)
      case .errorBody: writeErrorBodyMap(entries, nonStringKeys: nonStringKeys, depth: depth)
      }
    }
  }

  /// A list as a JSON array, or `{"list": [...], "omitted": n}`; an
  /// iterable as `{"iterable": [...], "omitted"?: n}`.
  private mutating func writeItems(_ items: [Any], tag: String, depth: Int) {
    let limit = rules == .parameters ? ValueWriter.parameterItemsSent : ValueWriter.errorBodyItemsSent
    let sent = items.prefix(limit)
    // Parameters stop after the 257th item without `omitted`: the engine's
    // item budget ends the collection by then.
    let omitted = rules == .errorBody ? items.count - sent.count : 0
    let tagged = tag == "iterable" || omitted > 0
    out += tagged ? "{\"\(tag)\":[" : "["
    var first = true
    for item in sent {
      if stopped { break }
      if !first { out += "," }
      first = false
      write(item, depth: depth + 1)
    }
    out += "]"
    guard tagged else { return }
    if omitted > 0 && !stopped {
      out += ",\"omitted\":\(omitted)"
    }
    out += "}"
  }

  /// Sorted string keys, then one `nonStringKeys` run. A key the engine
  /// rejects (empty or over 128 units) is folded into a run in its place,
  /// and the map stops after its 257th entry with a valid key.
  private mutating func writeParameterMap(_ entries: [(key: String, value: Any)], nonStringKeys: Int, depth: Int) {
    var map = MapEntries()
    var validEntries = 0
    out += "{\"map\":["
    for entry in entries {
      guard HostParameters.isValidKey(entry.key) else {
        map.skip(1)
        continue
      }
      if validEntries == ValueWriter.parameterItemsSent { break }
      validEntries += 1
      out += map.open(key: entry.key)
      write(entry.value, depth: depth + 1)
      out += "]"
    }
    if validEntries < ValueWriter.parameterItemsSent {
      map.skip(nonStringKeys)
    }
    out += map.flush() + "]}"
  }

  /// Sorted string keys (cut as strings are), then one `nonStringKeys`
  /// run; the first 128 entries, then `omitted`.
  private mutating func writeErrorBodyMap(_ entries: [(key: String, value: Any)], nonStringKeys: Int, depth: Int) {
    let limit = ValueWriter.errorBodyItemsSent
    var map = MapEntries()
    out += "{\"map\":["
    for entry in entries.prefix(limit) {
      if stopped { break }
      out += map.open(key: ValueWriter.errorBodyString(entry.key))
      write(entry.value, depth: depth + 1)
      out += "]"
    }
    let runSent = stopped ? 0 : min(nonStringKeys, max(0, limit - entries.count))
    map.skip(runSent)
    let omitted = stopped ? 0 : entries.count + nonStringKeys - min(entries.count, limit) - runSent
    out += map.flush() + "]" + (omitted > 0 ? ",\"omitted\":\(omitted)}" : "}")
  }

  /// A string or key of an error body: cut to at least 4097 UTF-16 units,
  /// at a code point boundary.
  private static func errorBodyString(_ value: String) -> String {
    prefix(value, longerThan: errorBodyStringUnits - 1) { $0.utf16.count }
  }

  /// `value` when its `size` is at most `limit`, else its shortest prefix of
  /// whole code points whose size passes `limit`.
  static func prefix(_ value: String, longerThan limit: Int, size: (Unicode.Scalar) -> Int) -> String {
    var total = 0
    var scalars = String.UnicodeScalarView()
    for scalar in value.unicodeScalars {
      scalars.append(scalar)
      total += size(scalar)
      if total > limit {
        return String(scalars)
      }
    }
    return value
  }
}

/// Separators of map entries: `[key, value]` entries, with consecutive
/// skipped keys written as one `{"nonStringKeys": n}`.
private struct MapEntries {
  private var count = 0
  private var skipped = 0

  mutating func skip(_ keys: Int) {
    skipped += keys
  }

  /// The text before an entry's value; the caller closes the entry with `]`.
  mutating func open(key: String) -> String {
    let out = flush() + (count > 0 ? "," : "") + "[" + JSONText.quoted(key) + ","
    count += 1
    return out
  }

  /// A pending run of skipped keys, if any.
  mutating func flush() -> String {
    guard skipped > 0 else { return "" }
    let out = (count > 0 ? "," : "") + "{\"nonStringKeys\":\(skipped)}"
    count += 1
    skipped = 0
    return out
  }
}

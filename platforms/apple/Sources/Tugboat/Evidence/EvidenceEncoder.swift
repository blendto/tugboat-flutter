import Foundation

/// Writes the app's typed values in the engine's value encoding
/// (core/session-engine/docs/evidence-messages.md section 2), with the host
/// obligations of section 4: Swift types (4.1), keys sorted by `String <`
/// with one `nonStringKeys` run after them (4.2), and the mandatory bounds
/// of 4.4 (parameters) and 4.5 (error bodies), which leave out only what
/// Dart never reads. Every other limit and policy rule is the engine's.
enum EvidenceEncoder {
  /// The `parameters` map value.
  static func parameters(_ list: HostParameterList) -> String {
    var writer = ValueWriter(rules: .parameters)
    writer.writeParameters(list)
    return writer.out
  }

  /// `{"value": <encoded>}`, or nil for no body (`nil`, `NSNull`, `Data`).
  /// A string is a text body; anything else is normalized by the engine,
  /// which keeps no body for a root it does not support.
  static func errorResponseBody(_ body: Any) -> String? {
    guard let body = ValueKind.unwrap(body), !ValueKind.isNoBody(body) else {
      return nil
    }
    var writer = ValueWriter(rules: .errorBody)
    writer.write(body, depth: 0)
    return "{\"value\":" + writer.out + "}"
  }
}

/// Writes values under the parameter rules (top-level values are depth 1,
/// one item budget for the whole tree) or the error-body rules (the root
/// is depth 0, per-collection caps, one node budget).
struct ValueWriter {
  enum Rules {
    case parameters
    case errorBody
  }

  /// Parameters: a value at this depth or deeper is unsupported.
  static let parameterDepthLimit = 5
  /// Parameters: a longer string is unsupported.
  static let parameterStringUnits = 1024
  /// Parameters: counted slots sent in the whole tree.
  static let parameterItemBudget = 256
  /// Error bodies: a collection at this depth or deeper is unsupported.
  static let errorBodyDepthLimit = 6
  /// Error bodies: items or entries sent per collection.
  static let errorBodyItemsSent = 128
  /// Error bodies: longer strings and keys are cut to this many units.
  static let errorBodyStringUnits = 4097
  /// Error bodies: writing stops after this many counted nodes.
  static let errorBodyNodeBudget = 4097

  let rules: Rules
  private(set) var out = ""
  /// The collections around the value being written, innermost last: the
  /// instance for a reference type (`NSArray`, `NSDictionary`, `NSSet`),
  /// nil for a Swift value, which cannot be its own ancestor.
  private var ancestors: [ObjectIdentifier?] = []
  /// Parameters: counted slots sent so far (section 4.4, `c`).
  private var itemsSent = 0
  /// Error bodies: counted nodes written so far.
  private var nodesWritten = 0
  /// Error bodies: open iterables, whose contents are not counted.
  private var openIterables = 0

  init(rules: Rules) {
    self.rules = rules
  }

  /// Error bodies: the node budget is spent, so nothing more is written.
  private var stopped: Bool {
    rules == .errorBody && nodesWritten >= ValueWriter.errorBodyNodeBudget
  }

  /// The top-level parameters map. Its entries are not counted slots.
  mutating func writeParameters(_ list: HostParameterList) {
    out += "{\"map\":["
    var separator = ""
    for entry in list.entries {
      out += separator + "[" + JSONText.quoted(entry.key) + ","
      separator = ","
      switch entry.value {
      case .unread: out += "null"
      case .dropped: out += "{\"drop\":true}"
      case let .kept(value): write(value, depth: 1)
      }
      out += "]"
    }
    if list.invalidKeys > 0 {
      out += separator + "{\"nonStringKeys\":\(list.invalidKeys)}"
    }
    out += "]"
    if list.omitted > 0 {
      out += ",\"omitted\":\(list.omitted)"
    }
    out += "}"
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
      if value.isFinite {
        emit(ValueKind.doubleJSON(value))
      } else {
        out += ValueKind.doubleJSON(value)
      }
    case let .string(value):
      writeString(value)
    case .unsupported:
      out += ValueKind.unsupportedJSON
    case let .collection(collection, identity):
      writeCollection(collection, identity: identity, depth: depth)
    }
  }

  /// Writes a node the error-body budget counts.
  private mutating func emit(_ json: String) {
    countNode()
    out += json
  }

  private mutating func countNode() {
    if openIterables == 0 {
      nodesWritten += 1
    }
  }

  private mutating func writeString(_ value: String) {
    switch rules {
    case .parameters:
      if value.utf16.count > ValueWriter.parameterStringUnits {
        out += ValueKind.unsupportedJSON
      } else {
        out += JSONText.quoted(value)
      }
    case .errorBody:
      emit(ValueWriter.quotedPrefix(value, units: ValueWriter.errorBodyStringUnits))
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
      countNode()
      writeItems(items, tag: "list", depth: depth)
    case let .iterable(items):
      openIterables += 1
      writeItems(items, tag: "iterable", depth: depth)
      openIterables -= 1
    case let .map(entries, nonStringKeys):
      countNode()
      switch rules {
      case .parameters: writeParameterMap(entries, nonStringKeys: nonStringKeys, depth: depth)
      case .errorBody: writeErrorBodyMap(entries, nonStringKeys: nonStringKeys, depth: depth)
      }
    }
  }

  /// A list as a JSON array or `{"list": [...], "omitted": n}`; an iterable
  /// as `{"iterable": [...], "omitted"?: n}`.
  private mutating func writeItems(_ items: [Any], tag: String, depth: Int) {
    var body = ""
    var omitted = 0
    swap(&body, &out)
    switch rules {
    case .parameters:
      for (index, item) in items.enumerated() {
        guard takeItemSlot() else {
          omitted = 1
          break
        }
        if index > 0 { out += "," }
        write(item, depth: depth + 1)
      }
    case .errorBody:
      let sent = items.prefix(ValueWriter.errorBodyItemsSent)
      omitted = items.count - sent.count
      for (index, item) in sent.enumerated() {
        if stopped { break }
        if index > 0 { out += "," }
        write(item, depth: depth + 1)
      }
    }
    swap(&body, &out)
    if tag == "list" && omitted == 0 {
      out += "[" + body + "]"
    } else {
      out += "{\"\(tag)\":[" + body + "]" + (omitted > 0 ? ",\"omitted\":\(omitted)" : "") + "}"
    }
  }

  /// Valid keys sorted by `String <`, then one `nonStringKeys` run for the
  /// invalid ones (not strings, empty, or over 128 units), whose values are
  /// not read. Each valid entry is a counted slot.
  private mutating func writeParameterMap(_ entries: [(key: String, value: Any)], nonStringKeys: Int, depth: Int) {
    var separator = ""
    var omitted = false
    var invalidKeys = nonStringKeys
    out += "{\"map\":["
    for entry in entries {
      guard HostParameters.isValidKey(entry.key) else {
        invalidKeys += 1
        continue
      }
      guard takeItemSlot() else {
        omitted = true
        break
      }
      out += separator + "[" + JSONText.quoted(entry.key) + ","
      separator = ","
      write(entry.value, depth: depth + 1)
      out += "]"
    }
    if !omitted && invalidKeys > 0 {
      out += separator + "{\"nonStringKeys\":\(invalidKeys)}"
    }
    out += omitted ? "],\"omitted\":1}" : "]}"
  }

  /// Sorted string keys (cut as strings are), then one `nonStringKeys` run;
  /// the first 128 entries, then `omitted`.
  private mutating func writeErrorBodyMap(_ entries: [(key: String, value: Any)], nonStringKeys: Int, depth: Int) {
    let limit = ValueWriter.errorBodyItemsSent
    let sent = entries.prefix(limit)
    let runSent = min(nonStringKeys, limit - sent.count)
    let omitted = entries.count + nonStringKeys - sent.count - runSent
    var separator = ""
    out += "{\"map\":["
    for entry in sent {
      if stopped { break }
      out += separator + "[" + ValueWriter.quotedPrefix(entry.key, units: ValueWriter.errorBodyStringUnits) + ","
      separator = ","
      write(entry.value, depth: depth + 1)
      out += "]"
    }
    if !stopped && runSent > 0 {
      out += separator + "{\"nonStringKeys\":\(runSent)}"
    }
    out += "]" + (omitted > 0 ? ",\"omitted\":\(omitted)}" : "}")
  }

  /// Parameters: claims the next counted slot of the item budget; false
  /// when it is spent.
  private mutating func takeItemSlot() -> Bool {
    guard itemsSent < ValueWriter.parameterItemBudget else { return false }
    itemsSent += 1
    return true
  }

  /// `value` as a JSON string, cut to its first `units` UTF-16 units. A cut
  /// through a surrogate pair keeps its high half as a `\uXXXX` escape.
  static func quotedPrefix(_ value: String, units: Int) -> String {
    guard value.utf16.count > units else { return JSONText.quoted(value) }
    var kept = String.UnicodeScalarView()
    var total = 0
    var split: UInt16?
    for scalar in value.unicodeScalars {
      let width = scalar.value > 0xFFFF ? 2 : 1
      if total + width > units {
        if total < units {
          split = UInt16(0xD800 + ((scalar.value - 0x10000) >> 10))
        }
        break
      }
      kept.append(scalar)
      total += width
    }
    let quoted = JSONText.quoted(String(kept))
    guard let high = split else { return quoted }
    return String(quoted.dropLast()) + "\\u" + String(high, radix: 16) + "\""
  }
}

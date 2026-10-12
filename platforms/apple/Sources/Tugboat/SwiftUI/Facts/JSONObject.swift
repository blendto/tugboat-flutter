import Foundation

/// A JSON value the adapter writes. Facts are small and built field by
/// field, so they are encoded by hand, in insertion order, with the host's
/// string escaping (`JSONText`).
indirect enum JSONValue: Equatable {
  case string(String)
  case int(Int64)
  case double(Double)
  case bool(Bool)
  case object(JSONObject)
  case array([JSONValue])

  var json: String {
    switch self {
    case let .string(value): return JSONText.quoted(value)
    case let .int(value): return String(value)
    case let .double(value): return JSONValue.number(value)
    case let .bool(value): return value ? "true" : "false"
    case let .object(value): return value.json
    case let .array(values): return "[" + values.map { $0.json }.joined(separator: ",") + "]"
    }
  }

  /// A JSON number. JSON has no NaN or infinity; the adapter never produces
  /// them on purpose, so a non-finite value (a degenerate geometry) is
  /// written as 0 rather than as invalid JSON.
  static func number(_ value: Double) -> String {
    guard value.isFinite else { return "0" }
    if value == value.rounded(), abs(value) < 1e15 {
      return String(Int64(value))
    }
    return String(value)
  }
}

/// A JSON object whose members keep insertion order. Setting an existing
/// key replaces its value in place.
struct JSONObject: Equatable {
  private(set) var members: [(key: String, value: JSONValue)] = []

  init() {}

  static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
    lhs.members.count == rhs.members.count
      && zip(lhs.members, rhs.members).allSatisfy { $0.key == $1.key && $0.value == $1.value }
  }

  subscript(key: String) -> JSONValue? {
    members.first { $0.key == key }?.value
  }

  mutating func set(_ key: String, _ value: JSONValue) {
    if let index = members.firstIndex(where: { $0.key == key }) {
      members[index].value = value
    } else {
      members.append((key, value))
    }
  }

  mutating func set(_ key: String, _ value: String) { set(key, .string(value)) }
  mutating func set(_ key: String, _ value: Double) { set(key, .double(value)) }
  mutating func set(_ key: String, _ value: Int64) { set(key, .int(value)) }
  mutating func set(_ key: String, _ value: Bool) { set(key, .bool(value)) }
  mutating func set(_ key: String, _ value: JSONObject) { set(key, .object(value)) }

  var json: String {
    "{" + members.map { JSONText.quoted($0.key) + ":" + $0.value.json }.joined(separator: ",") + "}"
  }
}

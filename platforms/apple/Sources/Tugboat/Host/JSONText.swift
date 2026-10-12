/// JSON text helpers for the few values the host itself writes (message
/// types, timer and request ids, response bodies). Caller-supplied JSON is
/// never parsed or re-encoded.
enum JSONText {
  /// `value` as a JSON string literal, quotes included.
  static func quoted(_ value: String) -> String {
    var out = "\""
    out.reserveCapacity(value.utf8.count + 2)
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      default:
        if scalar.value < 0x20 {
          out += controlEscape(scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    out += "\""
    return out
  }

  private static func controlEscape(_ value: UInt32) -> String {
    let hex = String(value, radix: 16)
    return "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
  }
}

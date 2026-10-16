import Foundation

/// An error body a byte-reading adapter did not decode: sent as
/// `{"jsonText": text}`, which the engine decodes as Dart's `jsonDecode`
/// would (evidence-messages.md section 3.2). Only `HTTPErrorBody` makes one;
/// the app cannot, so the manual API is unchanged.
struct JSONTextBody {
  let text: String
}

/// The error body of an HTTP response read from its bytes
/// (evidence-messages.md section 4.5, "a byte-reading adapter"): the
/// `URLSession` delegate, `Tugboat.data(for:session:delegate:route:)`, and
/// `TugboatAlamofire`.
enum HTTPErrorBody {
  /// The adapter keeps at most this many bytes (64 KiB + 1): the body is
  /// complete if and only if it kept at most `completeBytes`.
  /// `Content-Length` is not trusted.
  static let peekBytes = 65_537
  static let completeBytes = 65_536
  /// A text body is cut to the complete characters of this many bytes: any
  /// prefix past the engine's 4096-byte cut keeps the text body exact.
  static let textBytes = 4100

  /// The body for `complete(errorResponseBody:)` from the response bytes
  /// (all of them, or at least the first `peekBytes`; the rest is never
  /// read): `JSONTextBody` for a complete body with a JSON media type,
  /// otherwise the text, decoded with U+FFFD replacement
  /// (`String(decoding:as:)`, the maximal-subpart practice) and cut to whole
  /// characters within 4100 UTF-8 bytes. Empty bytes give no body.
  static func body(bytes: Data, contentType: String?) -> Any? {
    guard !bytes.isEmpty else { return nil }
    let kept = bytes.prefix(peekBytes)
    if kept.count <= completeBytes && isJSON(contentType: contentType) {
      return JSONTextBody(text: String(decoding: kept, as: UTF8.self))
    }
    return text(kept)
  }

  /// `bytes` decoded, then cut before the first character whose UTF-8
  /// encoding would pass 4100 bytes (a U+FFFD counts 3), so the text is
  /// whole characters of the full decoding (as `tugboat-okhttp` does).
  static func text(_ bytes: Data) -> String {
    let decoded = String(decoding: bytes, as: UTF8.self)
    guard decoded.utf8.count > textBytes else { return decoded }
    var kept = String.UnicodeScalarView()
    var written = 0
    for scalar in decoded.unicodeScalars {
      written += UTF8.width(scalar)
      if written > textBytes { break }
      kept.append(scalar)
    }
    return String(kept)
  }

  /// `Content-Type`, case-insensitive with its parameters ignored, is
  /// `application/json` or a `type/subtype` whose subtype ends in `+json`.
  static func isJSON(contentType: String?) -> Bool {
    guard let contentType = contentType else { return false }
    let mediaType = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first
      .map { asciiLowercased(trimmingHTTPWhitespace($0)) } ?? ""
    if mediaType == "application/json" {
      return true
    }
    let parts = mediaType.split(separator: "/", omittingEmptySubsequences: false)
    return parts.count == 2 && !parts[0].isEmpty && parts[1].hasSuffix("+json")
  }

  private static func trimmingHTTPWhitespace(_ text: Substring) -> Substring {
    let isSpace: (Character) -> Bool = { $0 == " " || $0 == "\t" }
    guard let start = text.firstIndex(where: { !isSpace($0) }) else { return "" }
    let end = text.lastIndex(where: { !isSpace($0) }) ?? start
    return text[start...end]
  }

  private static func asciiLowercased(_ text: Substring) -> String {
    String(decoding: text.utf8.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }, as: UTF8.self)
  }
}

/// Route and timing helpers shared by the automatic adapters.
enum NetworkRoute {
  /// The resolver's route, trimmed as Dart's `String.trim` does (as
  /// `tugboat_dio` does); nil when it returns nil or an empty route, or
  /// throws. Query strings never reach the engine unless the app's own
  /// resolver returns them, and the engine then rejects the route.
  static func resolve(_ resolver: (URLRequest) throws -> String?, _ request: URLRequest) -> String? {
    guard let route = (try? resolver(request)) ?? nil else { return nil }
    return trimmed(route)
  }

  /// `route` trimmed as Dart's `String.trim`; nil when empty.
  static func trimmed(_ route: String?) -> String? {
    guard let route = route else { return nil }
    let scalars = route.unicodeScalars
    guard let start = scalars.firstIndex(where: { !isDartWhitespace($0) }) else { return nil }
    let end = scalars.lastIndex(where: { !isDartWhitespace($0) }) ?? start
    return String(scalars[start...end])
  }

  /// Dart's `String.trim` whitespace (the engine's `is_dart_whitespace`).
  static func isDartWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
      return true
    default:
      return false
    }
  }

  /// The request method as URLSession sends it.
  static func method(_ request: URLRequest?) -> String {
    request?.httpMethod ?? "GET"
  }
}

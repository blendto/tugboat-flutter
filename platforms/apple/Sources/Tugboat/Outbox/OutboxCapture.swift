import Foundation

/// One logical unit of a collector request, with the stable key the host
/// derives for it from what it already sends (W11 design section 3.1).
struct OutboxUnit: Equatable {
  let key: String
  let lane: String
  let path: String
  let sessionId: String
  let payload: OutboxPayload
}

/// What a unit replays: a JSON body byte for byte, or one frame as a
/// one-frame multipart upload (the boundary is regenerated on replay).
enum OutboxPayload: Equatable {
  case json(String)
  case frame(fields: [FormField], filename: String, jpeg: Data)
}

/// Derives outbox units from an `http.send` request:
///
/// | Lane | Key |
/// | --- | --- |
/// | `lifecycle` | `<sessionId>/l/<eventType>/<triggeredAt>` from the JSON body |
/// | `events` | `<sessionId>/e/<sha256 of the sorted event ids, 16 hex>` |
/// | `frames` | one unit per frame, `<sessionId>/f/<frameNo>` |
///
/// nil when the request cannot be keyed (an unknown lane, a body without the
/// fields, a frame whose bytes are gone): it is then sent without an entry.
enum OutboxCapture {
  static func units(_ request: HTTPRequest, frameBytes: (_ handle: String) -> Data?) -> [OutboxUnit]? {
    switch (request.lane, request.body) {
    case let ("lifecycle", .json(text)):
      return lifecycle(request, text).map { [$0] }
    case let ("events", .json(text)):
      return events(request, text).map { [$0] }
    case let ("frames", .multipart(fields, frames)):
      return self.frames(request, fields, frames, frameBytes)
    default:
      return nil
    }
  }

  /// The `Tugboat-Delivery-Key` header value: the unit keys, comma-separated
  /// (a frame chunk carries one key per frame).
  static func headerValue(_ units: [OutboxUnit]) -> String {
    units.map { $0.key }.joined(separator: ",")
  }

  private static func lifecycle(_ request: HTTPRequest, _ text: String) -> OutboxUnit? {
    guard let object = jsonObject(text),
      let sessionId = nonEmpty(object["sessionId"]),
      let eventType = nonEmpty(object["eventType"]),
      let triggeredAt = nonEmpty(object["triggeredAt"])
    else { return nil }
    return OutboxUnit(
      key: "\(sessionId)/l/\(eventType)/\(triggeredAt)", lane: request.lane, path: request.path,
      sessionId: sessionId, payload: .json(text))
  }

  private static func events(_ request: HTTPRequest, _ text: String) -> OutboxUnit? {
    guard let object = jsonObject(text), let events = object["events"] as? [Any], !events.isEmpty else {
      return nil
    }
    var ids: [String] = []
    var sessionId: String?
    for item in events {
      guard let event = item as? [String: Any], let id = nonEmpty(event["id"]),
        let eventSession = nonEmpty(event["sessionId"])
      else { return nil }
      if sessionId == nil { sessionId = eventSession }
      ids.append(id)
    }
    guard let sessionId = sessionId else { return nil }
    let digest = OutboxDigest.sha256Hex(Data(ids.sorted().joined(separator: "\n").utf8))
    return OutboxUnit(
      key: "\(sessionId)/e/\(digest.prefix(16))", lane: request.lane, path: request.path,
      sessionId: sessionId, payload: .json(text))
  }

  private static func frames(
    _ request: HTTPRequest, _ fields: [FormField], _ frames: [FramePart], _ frameBytes: (String) -> Data?
  ) -> [OutboxUnit]? {
    guard let sessionId = field("sessionId", fields).flatMap({ nonEmpty($0) }),
      let frameNos = field("frameNos", fields),
      let metadata = field("frameMetadata", fields).flatMap({ JSONArrayText.elements($0) })
    else { return nil }
    let numbers = frameNos.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard !frames.isEmpty, numbers.count == frames.count, metadata.count == frames.count else { return nil }
    var units: [OutboxUnit] = []
    for (index, frame) in frames.enumerated() {
      let number = numbers[index]
      guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }), frame.filename == "\(number).jpg",
        let jpeg = frameBytes(frame.handle)
      else { return nil }
      let unitFields = [
        FormField(name: "sessionId", value: sessionId),
        FormField(name: "frameNos", value: number),
        FormField(name: "frameMetadata", value: "[\(metadata[index])]"),
      ]
      units.append(
        OutboxUnit(
          key: "\(sessionId)/f/\(number)", lane: request.lane, path: request.path, sessionId: sessionId,
          payload: .frame(fields: unitFields, filename: frame.filename, jpeg: jpeg)))
    }
    return units
  }

  private static func field(_ name: String, _ fields: [FormField]) -> String? {
    fields.first { $0.name == name }?.value
  }

  private static func jsonObject(_ text: String) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
  }

  private static func nonEmpty(_ value: Any?) -> String? {
    guard let string = value as? String, !string.isEmpty else { return nil }
    return string
  }
}

/// Splits a JSON array's text into its top-level elements' text, byte for
/// byte, so a one-frame upload carries exactly the metadata the engine
/// wrote. nil when the text is not an array.
enum JSONArrayText {
  static func elements(_ text: String) -> [String]? {
    let scalars = Array(text.unicodeScalars)
    var index = 0
    skipSpace(scalars, &index)
    guard index < scalars.count, scalars[index] == "[" else { return nil }
    index += 1
    var elements: [String] = []
    var depth = 0
    var inString = false
    var escaped = false
    var start = index
    while index < scalars.count {
      let scalar = scalars[index]
      if inString {
        if escaped {
          escaped = false
        } else if scalar == "\\" {
          escaped = true
        } else if scalar == "\"" {
          inString = false
        }
      } else if scalar == "\"" {
        inString = true
      } else if scalar == "[" || scalar == "{" {
        depth += 1
      } else if scalar == "}" || (scalar == "]" && depth > 0) {
        depth -= 1
      } else if depth == 0 && (scalar == "," || scalar == "]") {
        let element = trimmed(scalars[start..<index])
        if scalar == "]" {
          if !element.isEmpty || !elements.isEmpty { elements.append(element) }
          var rest = index + 1
          skipSpace(scalars, &rest)
          return rest == scalars.count && !elements.contains("") ? elements : nil
        }
        elements.append(element)
        start = index + 1
      }
      index += 1
    }
    return nil
  }

  private static func skipSpace(_ scalars: [Unicode.Scalar], _ index: inout Int) {
    while index < scalars.count, isSpace(scalars[index]) { index += 1 }
  }

  private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
    scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
  }

  private static func trimmed(_ slice: ArraySlice<Unicode.Scalar>) -> String {
    var view = String.UnicodeScalarView()
    view.append(contentsOf: slice)
    return String(view).trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r"))
  }
}

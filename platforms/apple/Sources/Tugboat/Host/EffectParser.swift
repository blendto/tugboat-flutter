import Foundation

/// Turns the `effects` array of an engine response into `Effect`s.
enum EffectParser {
  struct MalformedResponse: Error {}

  struct MalformedEffect: Error, CustomStringConvertible {
    let description: String
  }

  /// Effects of `response`, in order. A response without `effects` has none;
  /// an effect that breaks its schema is logged and skipped. Throws when
  /// `response` is not a JSON object.
  static func parse(_ response: Data) throws -> [Effect] {
    guard let document = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
      throw MalformedResponse()
    }
    guard let effects = document["effects"] as? [Any] else { return [] }
    var parsed: [Effect] = []
    for (index, item) in effects.enumerated() {
      do {
        parsed.append(try effect(item))
      } catch {
        HostLog.warning("dropping malformed effect \(index): \(error)")
      }
    }
    return parsed
  }

  private static func effect(_ item: Any) throws -> Effect {
    let fields = try Fields(item, what: "effect")
    let type = try fields.string("type")
    switch type {
    case "timer.schedule":
      return .timerSchedule(timerId: try fields.string("timerId"), atMonoUs: try fields.integer("atMonoUs"))
    case "timer.cancel":
      return .timerCancel(timerId: try fields.string("timerId"))
    case "http.send":
      return .httpSend(try httpRequest(fields))
    case "frame.release":
      return .frameRelease(handle: try fields.string("handle"))
    default:
      return .unknown(type: type)
    }
  }

  private static func httpRequest(_ fields: Fields) throws -> HTTPRequest {
    let body: HTTPBody
    if fields.has("jsonBody") {
      body = .json(try fields.string("jsonBody"))
    } else if fields.has("multipart") {
      body = try multipart(Fields(fields.value("multipart"), what: "multipart"))
    } else {
      throw MalformedEffect(description: "http.send needs jsonBody or multipart")
    }
    return HTTPRequest(
      requestId: try fields.string("requestId"),
      lane: try fields.string("lane"),
      path: try fields.string("path"),
      timeoutMs: Int(clamping: try fields.integer("timeoutMs")),
      body: body
    )
  }

  private static func multipart(_ multipart: Fields) throws -> HTTPBody {
    var formFields: [FormField] = []
    for (index, item) in try multipart.array("fields").enumerated() {
      guard let pair = item as? [Any], pair.count == 2,
        let name = pair[0] as? String, let value = pair[1] as? String
      else {
        throw MalformedEffect(description: "multipart field \(index) is not a [name, value] pair")
      }
      formFields.append(FormField(name: name, value: value))
    }
    var frames: [FramePart] = []
    for item in try multipart.array("frames") {
      let frame = try Fields(item, what: "frame")
      frames.append(FramePart(handle: try frame.string("handle"), filename: try frame.string("filename")))
    }
    return .multipart(fields: formFields, frames: frames)
  }
}

/// Strict typed reads from one JSON object.
private struct Fields {
  let object: [String: Any]

  init(_ value: Any?, what: String) throws {
    guard let object = value as? [String: Any] else {
      throw EffectParser.MalformedEffect(description: "\(what) is not an object")
    }
    self.object = object
  }

  func has(_ key: String) -> Bool {
    object[key] != nil
  }

  func value(_ key: String) -> Any? {
    object[key]
  }

  func string(_ key: String) throws -> String {
    guard let value = object[key] as? String else {
      throw EffectParser.MalformedEffect(description: "\(key) is not a string")
    }
    return value
  }

  /// An integral JSON number; booleans and fractions are rejected.
  func integer(_ key: String) throws -> Int64 {
    guard let number = object[key] as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      let value = number as? Int64
    else {
      throw EffectParser.MalformedEffect(description: "\(key) is not an integer")
    }
    return value
  }

  func array(_ key: String) throws -> [Any] {
    guard let value = object[key] as? [Any] else {
      throw EffectParser.MalformedEffect(description: "\(key) is not an array")
    }
    return value
  }
}

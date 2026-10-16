import Foundation
import TugboatSessionEngine
import XCTest

@testable import Tugboat

/// The shared `conformance/evidence` fixtures through the Swift host.
///
/// Each fixture's `input` is decoded into the Swift values an app would
/// pass (as the Dart runner does: `ref` a real `NSMutableArray` /
/// `NSMutableDictionary` cycle, `nonStringKeys` number keys, `omitted`
/// unsupported stand-ins, a top-level `drop` the transform's result), sent
/// through `TugboatEventHook` / `TugboatNetworkCall`, and the message the
/// host emits is run on the real engine.
///
/// Swift dictionaries have no order, so the host's map order is its own
/// (evidence-messages.md section 4.2). The check is therefore:
/// - every fixture: the engine records the same data for the Swift message
///   as for the fixture input with its maps put in Swift order;
/// - a fixture already in Swift order: that data is `expected.data`.
final class EvidenceConformanceTests: XCTestCase {
  /// Fixtures the Swift host cannot express, with the reason. Fixtures
  /// with a lone surrogate (a Swift `String` cannot hold one) are found by
  /// their text, and `jsonText` bodies are not part of the manual API.
  private static let notExpressible: [String: String] = [
    "iterable-copied-as-list": "Swift has no ordered iterable other than Array",
    "json-body-root-iterable": "Swift has no ordered iterable other than Array",
  ]

  private static let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("conformance/evidence")

  func testEveryFixtureThroughTheSwiftHost() throws {
    let files = try fixtureFiles()
    XCTAssertFalse(files.isEmpty, "conformance/evidence fixtures at \(Self.fixtures.path)")
    var ran = 0
    var dartOrdered = 0
    var exact = 0
    for file in files where Self.notExpressible[file.deletingPathExtension().lastPathComponent] == nil {
      let text = try String(contentsOf: file, encoding: .utf8)
      if Self.hasLoneSurrogate(text) {
        continue
      }
      let fixture = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], file.lastPathComponent)
      let name = fixture["name"] as? String ?? file.lastPathComponent
      guard let input = fixture["input"] as? [String: Any], let kind = fixture["kind"] as? String else {
        XCTFail("\(name): no input or kind")
        continue
      }
      if input["errorResponseBody"].map(isJSONText) == true || hasCycle(input) {
        continue
      }
      let emitted = try emit(kind: kind, input: input)
      let swiftOrdered = SwiftOrder.apply(to: input)
      let atMonoUs = finishMonoUs(kind: kind, input: input)
      // Nothing sent (an empty route) must mean nothing recorded.
      let fromSwift = try emitted.flatMap { try ConformanceEngine.record(type: kind, inputJSON: $0, atMonoUs: atMonoUs) }
      let fromFixture = try ConformanceEngine.record(type: kind, inputJSON: json(swiftOrdered), atMonoUs: atMonoUs)
      XCTAssertEqual(fromSwift as NSObject?, fromFixture as NSObject?, "\(name): engine data differs\n  sent \(emitted ?? "nothing")")
      if (swiftOrdered as NSDictionary).isEqual(to: input) {
        dartOrdered += 1
        let expected = (fixture["expected"] as? [String: Any])?["data"]
        XCTAssertEqual(
          fromSwift as NSObject?, (expected is NSNull ? nil : expected) as? NSObject, "\(name): differs from Dart")
      }
      if let emitted = emitted, (jsonObject(emitted) as NSDictionary).isEqual(to: input) {
        exact += 1
      }
      ran += 1
    }
    print("evidence fixtures: \(ran) of \(files.count) run, \(dartOrdered) in Swift order, \(exact) sent byte-for-byte")
    XCTAssertGreaterThan(ran, files.count / 2)
  }

  // MARK: - Sending a fixture through the host

  /// The input JSON the Swift host emits for the fixture, if any.
  private func emit(kind: String, input: [String: Any]) throws -> String? {
    let clock = FakeClock(monoUs: 0, wallUs: 1_791_712_345_678_901)
    let sink = RecordingEvidenceSink()
    let channel = EvidenceChannel(clock: clock, schedule: { $0() })
    channel.open(sink)
    if kind == EvidenceMessages.externalEvent {
      clock.set(monoUs: Int64(input["atMonoUs"] as? Int ?? 0))
      let (policy, parameters) = try decodeParameters(input)
      TugboatEventHook(source: input["source"] as? String, policy: policy, channel: channel)
        .record(input["name"] as? String ?? "", parameters: parameters)
    } else {
      clock.set(monoUs: Int64(input["startMonoUs"] as? Int ?? 0))
      let call = TugboatNetworkCall.begin(
        method: input["method"] as? String ?? "", route: input["route"] as? String, channel: channel)
      clock.set(monoUs: Int64(input["endMonoUs"] as? Int ?? input["startMonoUs"] as? Int ?? 0))
      let body = ((input["errorResponseBody"] as? [String: Any])?["value"]).map { FixtureDecoder().value($0) }
      let status = input["statusCode"] as? Int
      let attempts = input["attemptCount"] as? Int
      switch input["outcome"] as? String {
      case "network_error": call.fail(.networkError, statusCode: status, attemptCount: attempts, errorResponseBody: body)
      case "cancelled": call.fail(.cancelled, statusCode: status, attemptCount: attempts, errorResponseBody: body)
      default: call.complete(statusCode: status, attemptCount: attempts, errorResponseBody: body)
      }
    }
    return sink.posts.first?.inputJSON
  }

  /// The policy and the parameters an app would pass. Under `transform`
  /// the closure returns each key's sent value (or drops it).
  private func decodeParameters(_ input: [String: Any]) throws -> (TugboatParameterPolicy, [String: Any]?) {
    let policyJSON = input["policy"] as? [String: Any] ?? [:]
    guard let map = input["parameters"] as? [String: Any], let entries = map["map"] as? [Any] else {
      return (try policy(policyJSON, results: [:]), nil)
    }
    let decoder = FixtureDecoder()
    var parameters: [String: Any] = [:]
    var results: [String: Any] = [:]
    var invalidKeys = 0
    func addInvalidKey() {
      // A `[String: Any]` has only string keys: an invalid one is over 128 units.
      parameters[String(repeating: "~", count: 129) + String(invalidKeys)] = UnsupportedStandIn()
      invalidKeys += 1
    }
    for entry in entries {
      if let run = entry as? [String: Any], let count = run["nonStringKeys"] as? Int {
        for _ in 0..<count { addInvalidKey() }
        continue
      }
      let pair = try XCTUnwrap(entry as? [Any], "a top-level entry is [key, value] or a run")
      let key = try XCTUnwrap(pair.first as? String)
      let value = pair[1]
      if let tag = value as? [String: Any], tag["drop"] as? Bool == true {
        results[key] = TugboatParameterPolicy.drop
        parameters[key] = NSNull()
      } else {
        let decoded = decoder.value(value)
        results[key] = decoded
        parameters[key] = decoded
      }
    }
    // Each omitted top-level entry adds 1 to droppedCount with truncated, as
    // an invalid key does, so invalid keys stand in for them.
    for _ in 0..<(map["omitted"] as? Int ?? 0) { addInvalidKey() }
    return (try policy(policyJSON, results: results), parameters)
  }

  private func policy(_ json: [String: Any], results: [String: Any]) throws -> TugboatParameterPolicy {
    switch json["mode"] as? String {
    case "names_only": return .namesOnly
    case "allow_list": return .allowList(Set(json["allowedKeys"] as? [String] ?? []))
    case "transform":
      let results = results
      return .transform { key, value in results[key] ?? value }
    default: return .allowAll
    }
  }

  private func finishMonoUs(kind: String, input: [String: Any]) -> Int64 {
    if kind == EvidenceMessages.externalEvent {
      return Int64(input["atMonoUs"] as? Int ?? 0)
    }
    return Int64(input["endMonoUs"] as? Int ?? input["startMonoUs"] as? Int ?? 0)
  }

  // MARK: - Helpers

  /// A `\\uD800`–`\\uDFFF` escape that is not half of a pair.
  static func hasLoneSurrogate(_ text: String) -> Bool {
    let units = Array(text.lowercased().utf8)
    var index = 0
    func surrogate(at offset: Int) -> UInt8? {
      guard offset + 5 < units.count, units[offset] == UInt8(ascii: "\\"), units[offset + 1] == UInt8(ascii: "u"),
        units[offset + 2] == UInt8(ascii: "d")
      else { return nil }
      return units[offset + 3]
    }
    while index < units.count {
      if let nibble = surrogate(at: index), (UInt8(ascii: "8")...UInt8(ascii: "f")).contains(nibble) {
        let isHigh = (UInt8(ascii: "8")...UInt8(ascii: "b")).contains(nibble)
        let low = surrogate(at: index + 6)
        guard isHigh, let next = low, (UInt8(ascii: "c")...UInt8(ascii: "f")).contains(next) else { return true }
        index += 12
        continue
      }
      index += 1
    }
    return false
  }

  private func fixtureFiles() throws -> [URL] {
    guard let walker = FileManager.default.enumerator(at: Self.fixtures, includingPropertiesForKeys: nil) else { return [] }
    return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }
      .sorted { $0.path < $1.path }
  }

  private func isJSONText(_ body: Any) -> Bool {
    (body as? [String: Any])?["jsonText"] != nil
  }

  private func hasCycle(_ value: Any) -> Bool {
    #if canImport(Darwin)
    return false
    #else
    // Linux Foundation never returns from reading a self-containing NSArray.
    return json(value).contains("\"ref\"")
    #endif
  }

  private func json(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return "" }
    return String(decoding: data, as: UTF8.self)
  }
}

/// A value the encoding has no type for (`{"unsupported": true}`).
struct UnsupportedStandIn {}

/// Turns the value encoding back into the values an app would pass.
/// Collections are `NSMutableArray` / `NSMutableDictionary`, so a `ref`
/// can be a real cycle.
final class FixtureDecoder {
  private var ancestors: [AnyObject] = []
  private var nextNonStringKey = 0

  /// A key that sorts after every key of a fixture, for an omitted entry.
  static func omittedKey(_ index: Int) -> String {
    "\u{10FFFF}omitted\(index)"
  }

  func value(_ json: Any) -> Any {
    if json is NSNull { return NSNull() }
    if let number = json as? NSNumber {
      return CFGetTypeID(number) == CFBooleanGetTypeID() ? number.boolValue as Any : number.int64Value as Any
    }
    if let string = json as? String { return string }
    if let items = json as? [Any] { return list(items, omitted: 0) }
    guard let tag = json as? [String: Any] else { return UnsupportedStandIn() }
    if let double = tag["double"] { return self.double(double) }
    if let items = tag["list"] as? [Any] { return list(items, omitted: tag["omitted"] as? Int ?? 0) }
    if let items = tag["iterable"] as? [Any] {
      let set = NSMutableSet()
      for item in items { set.add(value(item)) }
      for _ in 0..<(tag["omitted"] as? Int ?? 0) { set.add(UnsupportedStandIn()) }
      return set
    }
    if let entries = tag["map"] as? [Any] { return map(entries, omitted: tag["omitted"] as? Int ?? 0) }
    if let levels = tag["ref"] as? Int, levels >= 1, levels <= ancestors.count {
      return ancestors[ancestors.count - levels]
    }
    return UnsupportedStandIn()
  }

  private func double(_ json: Any) -> Double {
    switch json as? String {
    case "NaN": return .nan
    case "Infinity": return .infinity
    case "-Infinity": return -.infinity
    case "-0.0": return -0.0
    default: return (json as? NSNumber)?.doubleValue ?? 0
    }
  }

  private func list(_ items: [Any], omitted: Int) -> NSMutableArray {
    let out = NSMutableArray()
    ancestors.append(out)
    for item in items { out.add(value(item)) }
    for _ in 0..<omitted { out.add(UnsupportedStandIn()) }
    ancestors.removeLast()
    return out
  }

  private func map(_ entries: [Any], omitted: Int) -> NSMutableDictionary {
    let out = NSMutableDictionary()
    ancestors.append(out)
    for entry in entries {
      if let pair = entry as? [Any], pair.count == 2, let key = pair[0] as? String {
        out[key as NSString] = value(pair[1])
      } else if let run = entry as? [String: Any], let count = run["nonStringKeys"] as? Int {
        for _ in 0..<count {
          out[NSNumber(value: nextNonStringKey)] = NSNull()
          nextNonStringKey += 1
        }
      }
    }
    for index in 0..<omitted { out[FixtureDecoder.omittedKey(index) as NSString] = UnsupportedStandIn() }
    ancestors.removeLast()
    return out
  }
}

/// A fixture input with every map's entries in the Swift host's order
/// (evidence-messages.md sections 4.2, 4.4): keys the engine accepts sorted
/// by `String <`, then one `nonStringKeys` run for the rest. In parameters
/// a string key must be 1 to 128 units; in an error body any string is.
enum SwiftOrder {
  static func apply(to input: [String: Any]) -> [String: Any] {
    var out = input
    if var parameters = input["parameters"] as? [String: Any], let entries = parameters["map"] as? [Any] {
      // Top level: the decoder stands omitted entries in as invalid keys,
      // which the engine counts the same, so `omitted` stays as it is.
      parameters["map"] = ordered(entries, parameters: true)
      out["parameters"] = parameters
    }
    if var body = input["errorResponseBody"] as? [String: Any], let inner = body["value"] {
      body["value"] = value(inner, parameters: false)
      out["errorResponseBody"] = body
    }
    return out
  }

  static func value(_ json: Any, parameters: Bool) -> Any {
    if let items = json as? [Any] { return items.map { value($0, parameters: parameters) } }
    guard var tag = json as? [String: Any] else { return json }
    if let items = tag["list"] as? [Any] { tag["list"] = items.map { value($0, parameters: parameters) } }
    if var entries = tag["map"] as? [Any] {
      // A nested omitted entry is a string-keyed unsupported value to the
      // decoder, so it sorts with the string keys, before the run.
      for index in 0..<(tag.removeValue(forKey: "omitted") as? Int ?? 0) {
        entries.append([FixtureDecoder.omittedKey(index), ["unsupported": true]])
      }
      tag["map"] = ordered(entries, parameters: parameters)
    }
    return tag
  }

  private static func ordered(_ entries: [Any], parameters: Bool) -> [Any] {
    var keyed: [(key: String, value: Any)] = []
    var run = 0
    for entry in entries {
      if let pair = entry as? [Any], pair.count == 2, let key = pair[0] as? String,
        !parameters || HostParameters.isValidKey(key)
      {
        keyed.append((key, value(pair[1], parameters: parameters)))
      } else if let tag = entry as? [String: Any], let count = tag["nonStringKeys"] as? Int {
        run += count
      } else {
        run += 1
      }
    }
    keyed.sort { $0.key < $1.key }
    var out: [Any] = keyed.map { [$0.key, $0.value] }
    if run > 0 { out.append(["nonStringKeys": run]) }
    return out
  }
}

/// A fresh real engine per message: the fixture runner's session, started
/// at `monoUs` 0.
enum ConformanceEngine {
  /// The recorded event's `data`; nil when nothing is recorded, a
  /// `rejected` document when the engine refuses the message.
  static func record(type: String, inputJSON: String, atMonoUs: Int64) throws -> [String: Any]? {
    let bridge = try XCTUnwrap(EngineBridge.open())
    defer { bridge.close() }
    let sink = EngineEvidenceSink(bridge: bridge)
    try sink.startSession(at: HostTime(monoUs: 0, wallUs: 1_791_712_345_678_901))
    let message = EngineMessage(type: type, inputJSON: inputJSON, at: HostTime(monoUs: atMonoUs, wallUs: 1_791_712_345_678_901))
    let response = bridge.submit(Data(message.json.utf8))
    guard response.status == TB_SESSION_OK else {
      return ["rejected": response.statusName]
    }
    let records = jsonObject(response.text)["records"] as? [[String: Any]] ?? []
    let events = records.filter { $0["kind"] as? String == "event" }.compactMap { $0["event"] as? [String: Any] }
    return events.last?["data"] as? [String: Any]
  }
}

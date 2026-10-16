#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import XCTest

@testable import Tugboat

/// The value encoding (evidence-messages.md section 2) and the Swift host
/// obligations (section 4): types, key order, bounds, cycles, elision.
final class EvidenceEncoderTests: XCTestCase {
  private let unsupported = "{\"unsupported\":true}"

  /// One parameter value as the encoder writes it (top level is depth 1).
  private func param(_ value: Any?) -> String {
    var writer = ValueWriter(rules: .parameters)
    writer.write(value, depth: 1)
    return writer.out
  }

  private func body(_ value: Any) -> String? {
    EvidenceEncoder.errorResponseBody(value)
  }

  // MARK: - Types

  func testNullsAndOptionals() {
    let none: Int? = nil
    let some: Int?? = 5
    XCTAssertEqual(param(nil), "null")
    XCTAssertEqual(param(NSNull()), "null")
    XCTAssertEqual(param(none as Any), "null")
    XCTAssertEqual(param(some as Any), "5")
  }

  func testBooleansAndIntegersByTheirExactType() {
    XCTAssertEqual(param(true), "true")
    XCTAssertEqual(param(NSNumber(value: false)), "false")
    XCTAssertEqual(param(NSNumber(value: 1)), "1", "an integer NSNumber is not a boolean")
    XCTAssertEqual(param(Int8(-5)), "-5")
    XCTAssertEqual(param(Int.min), String(Int.min))
    XCTAssertEqual(param(UInt64(Int64.max)), String(Int64.max))
    XCTAssertEqual(param(UInt64.max), unsupported, "beyond Int64")
    XCTAssertEqual(param(NSNumber(value: UInt64.max)), unsupported)
    XCTAssertEqual(param(UInt32.max), String(UInt32.max))
  }

  func testFloatingPointIsAlwaysTagged() {
    XCTAssertEqual(param(1.0), "{\"double\":1.0}")
    XCTAssertEqual(param(-2.5), "{\"double\":-2.5}")
    XCTAssertEqual(param(1e-5), "{\"double\":1e-05}")
    XCTAssertEqual(param(Float(0.5)), "{\"double\":0.5}")
    XCTAssertEqual(param(CGFloat(3)), "{\"double\":3.0}")
    XCTAssertEqual(param(NSNumber(value: 1.5)), "{\"double\":1.5}")
    XCTAssertEqual(param(Double.nan), "{\"double\":\"NaN\"}")
    XCTAssertEqual(param(Double.infinity), "{\"double\":\"Infinity\"}")
    XCTAssertEqual(param(-Double.infinity), "{\"double\":\"-Infinity\"}")
    XCTAssertEqual(param(-0.0), "{\"double\":\"-0.0\"}")
    XCTAssertEqual(param(0.0), "{\"double\":0.0}")
  }

  func testStrings() {
    XCTAssertEqual(param("a\"b\\c\nd é 😀"), "\"a\\\"b\\\\c\\nd é 😀\"")
    XCTAssertEqual(param(NSString(string: "ns")), "\"ns\"")
  }

  func testEverythingElseIsUnsupported() {
    let values: [Any] = [
      Character("c"), Decimal(1), NSDecimalNumber(value: 1), Data([1]), Date(), TugboatParameterPolicy.drop,
      URL(fileURLWithPath: "/"), NSObject(),
    ]
    for value in values {
      XCTAssertEqual(param(value), unsupported, "\(type(of: value))")
    }
    XCTAssertEqual(param(["x": TugboatParameterPolicy.drop]), "{\"map\":[[\"x\",\(unsupported)]]}")
  }

  // MARK: - Collections and key order

  func testListsSetsAndSortedMaps() {
    XCTAssertEqual(param([1, "a", true] as [Any]), "[1,\"a\",true]")
    XCTAssertEqual(param(NSArray(array: [1, 2])), "[1,2]")
    XCTAssertEqual(param(Set([7])), "{\"iterable\":[7]}")
    XCTAssertEqual(param(NSSet(array: ["s"])), "{\"iterable\":[\"s\"]}")
    XCTAssertEqual(
      param(["b": ["z": 1, "a": 2], "B": 3, "a": 4] as [String: Any]),
      "{\"map\":[[\"B\",3],[\"a\",4],[\"b\",{\"map\":[[\"a\",2],[\"z\",1]]}]]}")
    XCTAssertEqual(param(NSDictionary(dictionary: ["y": 1, "x": 2])), "{\"map\":[[\"x\",2],[\"y\",1]]}")
    XCTAssertEqual(param([String: Any]()), "{\"map\":[]}")
    XCTAssertEqual(param([Any]()), "[]")
  }

  func testNonStringKeysFollowTheSortedStringKeysAsOneRun() {
    let mixed: [AnyHashable: Any] = ["b": 1, 2: "x", "a": 2, 3.5: "y"]
    XCTAssertEqual(param(mixed), "{\"map\":[[\"a\",2],[\"b\",1],{\"nonStringKeys\":2}]}")
    XCTAssertEqual(param([1: "one"]), "{\"map\":[{\"nonStringKeys\":1}]}")
  }

  func testInvalidNestedKeysAreFoldedInPlaceWithoutTheirValues() {
    let long = String(repeating: "k", count: 129)
    let map: [AnyHashable: Any] = ["": Data(), "a": 1, long: Data(), "zz": 2, 9: 3]
    XCTAssertEqual(
      param(map),
      "{\"map\":[{\"nonStringKeys\":1},[\"a\",1],{\"nonStringKeys\":1},[\"zz\",2],{\"nonStringKeys\":1}]}")
    let trailing: [AnyHashable: Any] = ["~": 1, "a": 1, 9: 3]
    XCTAssertEqual(param(trailing), "{\"map\":[[\"a\",1],[\"~\",1],{\"nonStringKeys\":1}]}")
    let merged: [AnyHashable: Any] = ["a": 1, String(repeating: "z", count: 200): 1, 9: 3]
    XCTAssertEqual(param(merged), "{\"map\":[[\"a\",1],{\"nonStringKeys\":2}]}", "adjacent runs merge")
  }

  // MARK: - Bounds and elision (parameters)

  func testParameterValuesAtDepthFiveAreUnsupported() {
    XCTAssertEqual(param([[[[1]]]]), "[[[[\(unsupported)]]]]")
    XCTAssertEqual(param([[[[[1]]]]]), "[[[[\(unsupported)]]]]")
    XCTAssertEqual(param(["a": ["b": ["c": ["d": 1]]]]), "{\"map\":[[\"a\",{\"map\":[[\"b\",{\"map\":[[\"c\",{\"map\":[[\"d\",\(unsupported)]]}]]}]]}]]}")
  }

  func testParameterStringsOver1024UnitsAreUnsupported() {
    XCTAssertEqual(param(String(repeating: "s", count: 1024)), "\"" + String(repeating: "s", count: 1024) + "\"")
    XCTAssertEqual(param(String(repeating: "s", count: 1025)), unsupported)
    XCTAssertEqual(param(String(repeating: "😀", count: 513)), unsupported, "1026 UTF-16 units")
  }

  func testParameterCollectionsStopAfter257Items() throws {
    let list = try parsed(param(Array(0..<300)))
    XCTAssertEqual((list as? [Any])?.count, 257)
    let map = Dictionary(uniqueKeysWithValues: (0..<300).map { (String(format: "k%03d", $0), $0) })
    let entries = try XCTUnwrap((try parsed(param(map)) as? [String: Any])?["map"] as? [Any])
    XCTAssertEqual(entries.count, 257)
    let set = try XCTUnwrap((try parsed(param(Set(0..<300))) as? [String: Any])?["iterable"] as? [Any])
    XCTAssertEqual(set.count, 257)
  }

  // MARK: - Cycles

  // Darwin only: Linux Foundation bridges a self-containing `NSArray` to a
  // Swift array on any element read, and never returns.
  #if canImport(Darwin)
  func testCyclesAreRefsToTheAncestor() {
    let array = NSMutableArray()
    array.add(1)
    array.add(array)
    XCTAssertEqual(param(array), "[1,{\"ref\":1}]")

    let dictionary = NSMutableDictionary()
    dictionary["self"] = dictionary
    XCTAssertEqual(param(dictionary), "{\"map\":[[\"self\",{\"ref\":1}]]}")

    let outer = NSMutableArray()
    let inner = NSMutableArray()
    outer.add(["wrap": inner])
    inner.add(outer)
    XCTAssertEqual(param(outer), "[{\"map\":[[\"wrap\",[{\"ref\":3}]]]}]", "a Swift dictionary is a level too")
  }

  func testTheParametersMapItselfIsNotAnAncestor() {
    let dictionary = NSMutableDictionary()
    dictionary["self"] = dictionary
    // `[String: Any]` bridged from the same instance: its value is written once as a map.
    let parameters = HostParameterList(entries: [HostParameter(key: "self", value: .kept(dictionary))], omitted: 0)
    XCTAssertEqual(
      EvidenceEncoder.parameters(parameters), "{\"map\":[[\"self\",{\"map\":[[\"self\",{\"ref\":1}]]}]]}")
  }

  func testErrorBodyCyclesAreRefs() {
    let array = NSMutableArray()
    array.add(array)
    XCTAssertEqual(body(array), "{\"value\":[{\"ref\":1}]}")
  }
  #endif

  func testASharedButNotEnclosingInstanceIsWrittenInFull() {
    let shared = NSArray(array: [1])
    XCTAssertEqual(param(NSArray(array: [shared, shared])), "[[1],[1]]")
    XCTAssertEqual(param(NSArray(array: [NSArray(array: [1]), NSArray(array: [1])])), "[[1],[1]]")
  }

  // MARK: - Parameters map

  func testTheParametersMapCarriesDropsUnreadValuesAndOmitted() {
    let list = HostParameterList(
      entries: [
        HostParameter(key: "a", value: .kept(1.0)), HostParameter(key: "b", value: .dropped),
        HostParameter(key: "c", value: .unread),
      ],
      omitted: 3)
    XCTAssertEqual(
      EvidenceEncoder.parameters(list),
      "{\"map\":[[\"a\",{\"double\":1.0}],[\"b\",{\"drop\":true}],[\"c\",null]],\"omitted\":3}")
  }

  // MARK: - Error bodies

  func testErrorBodyRoots() {
    XCTAssertEqual(body("not found"), "{\"value\":\"not found\"}")
    XCTAssertEqual(body(["error": "x"]), "{\"value\":{\"map\":[[\"error\",\"x\"]]}}")
    XCTAssertEqual(body([1, 2]), "{\"value\":[1,2]}")
    XCTAssertEqual(body(42), "{\"value\":42}")
    XCTAssertNil(body(Data("{}".utf8)))
    XCTAssertNil(body(NSData()))
    XCTAssertNil(body(NSNull()))
    XCTAssertNil(body(Optional<Any>.none as Any))
  }

  func testTextBodiesAreCutJustPast4096Bytes() throws {
    let ascii = try XCTUnwrap(textBody(String(repeating: "a", count: 10_000)))
    XCTAssertEqual(ascii.utf8.count, 4097)
    let accented = try XCTUnwrap(textBody(String(repeating: "é", count: 3000)))
    XCTAssertEqual(accented.unicodeScalars.count, 2049, "4098 bytes: whole code points")
    XCTAssertEqual(try XCTUnwrap(textBody(String(repeating: "a", count: 4096))).utf8.count, 4096)
  }

  func testErrorBodyCollectionsSend128ItemsThenOmitted() throws {
    let list = try XCTUnwrap(parsedBody(Array(0..<200)) as? [String: Any])
    XCTAssertEqual((list["list"] as? [Any])?.count, 128)
    XCTAssertEqual(list["omitted"] as? Int, 72)
    XCTAssertEqual(try parsedBody(Array(0..<128)) as? [Int], Array(0..<128))

    let map = Dictionary(uniqueKeysWithValues: (0..<130).map { (String(format: "k%03d", $0), $0) })
    let mapJSON = try XCTUnwrap(parsedBody(map) as? [String: Any])
    XCTAssertEqual((mapJSON["map"] as? [Any])?.count, 128)
    XCTAssertEqual(mapJSON["omitted"] as? Int, 2)

    var mixed: [AnyHashable: Any] = Dictionary(uniqueKeysWithValues: (0..<127).map { (AnyHashable(String(format: "k%03d", $0)), $0 as Any) })
    for key in 0..<3 { mixed[AnyHashable(key)] = key }
    let mixedJSON = try XCTUnwrap(parsedBody(mixed) as? [String: Any])
    let entries = try XCTUnwrap(mixedJSON["map"] as? [Any])
    XCTAssertEqual(entries.count, 128)
    XCTAssertEqual(entries.last as? [String: Int], ["nonStringKeys": 1])
    XCTAssertEqual(mixedJSON["omitted"] as? Int, 2)
  }

  func testErrorBodyCollectionsAtDepthSixAreUnsupported() {
    XCTAssertEqual(body([[[[[[1]]]]]]), "{\"value\":[[[[[[1]]]]]]}", "a scalar at depth 6 is still sent")
    XCTAssertEqual(body([[[[[[[1]]]]]]]), "{\"value\":[[[[[[\(unsupported)]]]]]]}")
  }

  func testErrorBodyStringsAndKeysAreCutTo4097Units() throws {
    let long = String(repeating: "x", count: 5000)
    let json = try XCTUnwrap(parsedBody([long: long]) as? [String: Any])
    let entry = try XCTUnwrap((json["map"] as? [[String]])?.first)
    XCTAssertEqual(entry.map { $0.utf16.count }, [4097, 4097])
    let emoji = try XCTUnwrap(parsedBody([String(repeating: "😀", count: 3000)]) as? [String])
    XCTAssertEqual(emoji.first?.utf16.count, 4098, "cut after a whole code point")
  }

  func testErrorBodyWritingStopsAfter4097Values() throws {
    let nested = Array(repeating: Array(0..<128), count: 128)
    let json = try XCTUnwrap(parsedBody(nested) as? [[Int]])
    // root 1 + 31 full lists of 1 + 128, then the 32nd list and 96 items: 4097.
    XCTAssertEqual(json.count, 32)
    XCTAssertEqual(json.last?.count, 96)
  }

  // MARK: - Helpers

  private func parsed(_ json: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
  }

  private func parsedBody(_ value: Any) throws -> Any? {
    let wrapped = try XCTUnwrap(body(value))
    return (try parsed(wrapped) as? [String: Any])?["value"]
  }

  private func textBody(_ text: String) throws -> String? {
    try parsedBody(text) as? String
  }
}

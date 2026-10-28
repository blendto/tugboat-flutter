import Foundation
import XCTest

@testable import Tugboat

/// The host's part of the parameter policy (evidence-messages.md sections
/// 4.2–4.4): sorted valid keys, one run for invalid keys, the first 64
/// entries, and the transform.
final class HostParametersTests: XCTestCase {
  func testValidKeysAreSortedAndInvalidKeysBecomeOneRun() {
    let parameters: [String: Any] = [
      "b": 1, "B": 2, "a": 3, "é": 4, "aa": 5, "": 6, String(repeating: "k", count: 129): 7,
    ]
    let list = HostParameters.apply(.allowAll, to: parameters)
    XCTAssertEqual(list.entries.map { $0.key }, ["B", "a", "aa", "b", "é"])
    XCTAssertEqual(list.invalidKeys, 2)
    XCTAssertEqual(list.omitted, 0)
  }

  func testOnlyTheFirst64EntriesAreSentWithTheExactCountOfTheRest() {
    let parameters = Dictionary(uniqueKeysWithValues: (0..<100).map { (String(format: "k%03d", $0), $0 as Any) })
    let list = HostParameters.apply(.allowAll, to: parameters)

    XCTAssertEqual(list.entries.map { $0.key }, (0..<64).map { String(format: "k%03d", $0) })
    XCTAssertEqual(list.invalidKeys, 0)
    XCTAssertEqual(list.omitted, 36)
    XCTAssertEqual(HostParameters.apply(.allowAll, to: ["a": 1]).omitted, 0)
  }

  func testTheRunCountsTowardsThe64() {
    var parameters = Dictionary(uniqueKeysWithValues: (0..<60).map { (String(format: "k%02d", $0), $0 as Any) })
    for index in 0..<10 {
      parameters[String(repeating: "x", count: 129 + index)] = index
    }
    let list = HostParameters.apply(.allowAll, to: parameters)
    XCTAssertEqual(list.entries.count, 60)
    XCTAssertEqual(list.invalidKeys, 4)
    XCTAssertEqual(list.omitted, 6)
  }

  func testValuesTheEngineNeverReadsAreUnread() {
    let parameters: [String: Any] = ["method": "email", "secret": "x"]
    XCTAssertEqual(describe(.namesOnly, parameters), ["unread", "unread"])
    XCTAssertEqual(describe(.allowList(["method"]), parameters), ["kept(email)", "unread"])
    XCTAssertEqual(describe(.allowAll, parameters), ["kept(email)", "kept(x)"])
  }

  func testKeyValidityCountsUTF16Units() {
    XCTAssertTrue(HostParameters.isValidKey(String(repeating: "k", count: 128)))
    XCTAssertFalse(HostParameters.isValidKey(String(repeating: "k", count: 129)))
    XCTAssertFalse(HostParameters.isValidKey(""))
    XCTAssertTrue(HostParameters.isValidKey(String(repeating: "😀", count: 64)), "128 units")
    XCTAssertFalse(HostParameters.isValidKey(String(repeating: "😀", count: 64) + "k"), "129 units")
  }

  func testTransformKeepsReplacesDropsAndCatches() {
    let policy = TugboatParameterPolicy.transform { key, value in
      switch key {
      case "drop": return TugboatParameterPolicy.drop
      case "throw": throw TransformFailure()
      case "nil": return nil
      case "upper": return (value as? String)?.uppercased()
      case "optionalDrop": return Optional<Any>.some(TugboatParameterPolicy.drop)
      default: return value
      }
    }
    let parameters: [String: Any] = ["drop": 1, "throw": 2, "nil": 3, "upper": "abc", "keep": 4, "optionalDrop": 5]

    XCTAssertEqual(
      describe(policy, parameters),
      ["dropped", "kept(4)", "kept(nil)", "dropped", "dropped", "kept(ABC)"])
  }

  func testTransformRunsOnceForEachSentValidKey() {
    let calls = Locked<[String]>([])
    let policy = TugboatParameterPolicy.transform { key, value in
      calls.withLock { $0.append(key) }
      return value
    }
    var parameters = Dictionary(uniqueKeysWithValues: (0..<70).map { (String(format: "k%02d", $0), $0 as Any) })
    parameters[""] = "empty"
    parameters[String(repeating: "a", count: 129)] = "long"
    let list = HostParameters.apply(policy, to: parameters)

    XCTAssertEqual(calls.current, (0..<64).map { String(format: "k%02d", $0) })
    XCTAssertEqual(list.invalidKeys, 0, "the 64 sent entries are all valid")
    XCTAssertEqual(list.omitted, 8)
  }

  private func describe(_ policy: TugboatParameterPolicy, _ parameters: [String: Any]) -> [String] {
    HostParameters.apply(policy, to: parameters).entries.map { describeValue($0.value) }
  }

  private func describeValue(_ value: HostParameter.Value) -> String {
    switch value {
    case .dropped: return "dropped"
    case .unread: return "unread"
    case let .kept(value): return "kept(\(value.map { "\($0)" } ?? "nil"))"
    }
  }
}

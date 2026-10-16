import Foundation
import XCTest

@testable import Tugboat

/// The host's part of the parameter policy (evidence-messages.md sections
/// 4.2, 4.3, 4.5): sorted keys, the first 64 entries, and the transform.
final class HostParametersTests: XCTestCase {
  func testKeysAreSortedByStringLessThan() {
    let parameters: [String: Any] = ["b": 1, "B": 2, "a": 3, "é": 4, "aa": 5, "": 6]
    XCTAssertEqual(HostParameters.apply(.allowAll, to: parameters).entries.map { $0.key }, ["", "B", "a", "aa", "b", "é"])
  }

  func testOnlyTheFirst64EntriesAreSentWithTheExactCountOfTheRest() {
    let parameters = Dictionary(uniqueKeysWithValues: (0..<100).map { (String(format: "k%03d", $0), $0 as Any) })
    let list = HostParameters.apply(.allowAll, to: parameters)

    XCTAssertEqual(list.entries.map { $0.key }, (0..<64).map { String(format: "k%03d", $0) })
    XCTAssertEqual(list.omitted, 36)
    XCTAssertEqual(HostParameters.apply(.allowAll, to: ["a": 1]).omitted, 0)
  }

  func testValuesTheEngineNeverReadsAreUnread() {
    let parameters: [String: Any] = ["method": "email", "secret": "x", "": "empty key"]
    XCTAssertEqual(describe(.namesOnly, parameters), ["unread", "unread", "unread"])
    XCTAssertEqual(describe(.allowList(["method"]), parameters), ["unread", "kept(email)", "unread"])
    XCTAssertEqual(describe(.allowAll, parameters), ["unread", "kept(email)", "kept(x)"])
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

  func testTransformRunsOnceForEachValidKeyAmongTheFirst64() {
    let calls = Locked<[String]>([])
    let policy = TugboatParameterPolicy.transform { key, value in
      calls.withLock { $0.append(key) }
      return value
    }
    var parameters = Dictionary(uniqueKeysWithValues: (0..<70).map { (String(format: "k%02d", $0), $0 as Any) })
    parameters[""] = "empty"
    parameters[String(repeating: "a", count: 129)] = "long"
    let list = HostParameters.apply(policy, to: parameters)

    // Sorted: "", "aaa…" (129), then k00…k69; the first 64 hold k00…k61.
    XCTAssertEqual(calls.current, (0..<62).map { String(format: "k%02d", $0) })
    XCTAssertEqual(describeValue(list.entries[0].value), "unread")
    XCTAssertEqual(describeValue(list.entries[1].value), "unread")
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

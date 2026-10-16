import Foundation
import XCTest

@testable import Tugboat

/// `TugboatEventHook` and the host's part of the parameter policy: the
/// policy wire shape, sorted keys, and the `transform` closure.
final class EventHookTests: XCTestCase {
  func testRecordPostsAnExternalEventAtTheCallTime() throws {
    let fixture = EvidenceFixture()
    fixture.clock.set(monoUs: 1_500_000)
    fixture.hook(source: "analytics", policy: .allowList(["method", "a", "Z"])).record("USER_LOGIN")
    fixture.drain()

    let post = try XCTUnwrap(fixture.sink.posts.first)
    XCTAssertEqual(post.type, "evidence.externalEvent")
    XCTAssertEqual(post.at.monoUs, 1_500_000)
    XCTAssertEqual(
      post.inputJSON,
      "{\"name\":\"USER_LOGIN\",\"source\":\"analytics\",\"policy\":{\"mode\":\"allow_list\",\"allowedKeys\":[\"Z\",\"a\",\"method\"]}}")
  }

  func testPolicyModesAndAnOmittedSource() {
    let fixture = EvidenceFixture()
    for policy: TugboatParameterPolicy in [.namesOnly, .allowAll, .transform { _, value in value }, .allowList([])] {
      fixture.hook(source: nil, policy: policy).record("E")
    }
    fixture.drain()

    XCTAssertEqual(
      fixture.sink.posts.map { $0.inputJSON },
      [
        "{\"name\":\"E\",\"policy\":{\"mode\":\"names_only\"}}",
        "{\"name\":\"E\",\"policy\":{\"mode\":\"allow_all\"}}",
        "{\"name\":\"E\",\"policy\":{\"mode\":\"transform\"}}",
        "{\"name\":\"E\",\"policy\":{\"mode\":\"allow_list\",\"allowedKeys\":[]}}",
      ])
  }

  func testNamesAndSourcesArePassedThroughForTheEngineToBound() {
    let fixture = EvidenceFixture()
    let long = String(repeating: "n", count: 300)
    fixture.hook(source: "  src\n").record(long)
    fixture.drain()

    let input = fixture.sink.posts.first?.input ?? [:]
    XCTAssertEqual(input["name"] as? String, long)
    XCTAssertEqual(input["source"] as? String, "  src\n")
  }

  func testTheDefaultHookPolicyIsAllowAll() {
    XCTAssertEqual(TugboatParameterPolicy.allowAll.mode, "allow_all")
  }

  func testNothingIsRecordedWhenNotStartedStoppedOrDisabled() {
    let fixture = EvidenceFixture(open: false)
    let hook = fixture.hook(policy: .transform { _, _ in
      XCTFail("no transform runs while nothing accepts evidence")
      return nil
    })
    hook.record("before-start", parameters: ["k": 1])
    fixture.channel.open(fixture.sink)
    fixture.sink.isRunning = false
    hook.record("disabled", parameters: ["k": 1])
    fixture.sink.isRunning = true
    fixture.channel.close()
    hook.record("stopped", parameters: ["k": 1])
    fixture.drain()

    XCTAssertTrue(fixture.sink.posts.isEmpty)
  }

  func testAHookFollowsTheSessionRunningAtRecordTime() {
    let fixture = EvidenceFixture(open: false)
    let hook = fixture.hook()
    fixture.channel.open(fixture.sink)
    hook.record("first")
    // `stop` closes the channel on the main thread, after the hops queued before it.
    fixture.hop.sync { fixture.channel.close() }
    let next = RecordingEvidenceSink()
    fixture.channel.open(next)
    hook.record("second")
    fixture.drain()

    XCTAssertEqual(fixture.sink.posts.compactMap { $0.input["name"] as? String }, ["first"])
    XCTAssertEqual(next.posts.compactMap { $0.input["name"] as? String }, ["second"])
  }

  func testRecordsFromOneThreadKeepTheirOrder() {
    let fixture = EvidenceFixture()
    let hook = fixture.hook()
    let done = expectation(description: "recorded")
    DispatchQueue.global().async {
      for index in 0..<50 {
        hook.record("e\(index)")
      }
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    fixture.drain()

    XCTAssertEqual(fixture.sink.posts.compactMap { $0.input["name"] as? String }, (0..<50).map { "e\($0)" })
  }

  // MARK: - Host parameters

  func testKeysAreSortedByStringLessThan() {
    let parameters: [String: Any] = ["b": 1, "B": 2, "a": 3, "é": 4, "aa": 5, "": 6]
    XCTAssertEqual(HostParameters.apply(.allowAll, to: parameters).map { $0.key }, ["", "B", "a", "aa", "b", "é"])
    XCTAssertEqual(
      HostParameters.apply(.transform { _, value in value }, to: parameters).map { $0.key },
      ["", "B", "a", "aa", "b", "é"])
  }

  func testOnlyTransformRunsInTheHost() {
    let parameters: [String: Any] = ["method": "email", "secret": "x"]
    for policy: TugboatParameterPolicy in [.namesOnly, .allowList(["method"]), .allowAll] {
      let kept = HostParameters.apply(policy, to: parameters).map { describe($0.value) }
      XCTAssertEqual(kept, ["kept(email)", "kept(x)"], "\(policy.mode) is applied by the engine")
    }
  }

  func testTransformKeepsReplacesDropsAndCatches() {
    let policy = TugboatParameterPolicy.transform { key, value in
      switch key {
      case "drop": return TugboatParameterPolicy.drop
      case "throw": throw TransformFailure()
      case "nil": return nil
      case "upper": return (value as? String)?.uppercased()
      default: return value
      }
    }
    let parameters: [String: Any] = ["drop": 1, "throw": 2, "nil": 3, "upper": "abc", "keep": 4]
    let out = HostParameters.apply(policy, to: parameters)

    XCTAssertEqual(out.map { $0.key }, ["drop", "keep", "nil", "throw", "upper"])
    XCTAssertEqual(out.map { describe($0.value) }, ["dropped", "kept(4)", "kept(nil)", "dropped", "kept(ABC)"])
  }

  func testTransformRunsOnTheCallingThread() {
    let fixture = EvidenceFixture()
    let threads = Locked<[Bool]>([])
    let hook = fixture.hook(policy: .transform { _, value in
      threads.withLock { $0.append(Thread.isMainThread) }
      return value
    })
    let done = expectation(description: "recorded")
    DispatchQueue.global().async {
      hook.record("E", parameters: ["a": 1, "b": 2])
      XCTAssertEqual(threads.current.count, 2, "ran before record returned")
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    XCTAssertEqual(threads.current, [false, false])
  }

  private func describe(_ value: HostParameter.Value) -> String {
    switch value {
    case .dropped: return "dropped"
    case let .kept(value): return "kept(\(value.map { "\($0)" } ?? "nil"))"
    }
  }
}

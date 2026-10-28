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

  func testParametersAreAnEncodedMapAndEmptyParametersAreOmitted() {
    let fixture = EvidenceFixture()
    fixture.hook(policy: .allowList(["method"])).record("USER_LOGIN", parameters: ["method": "email", "email": "u@x"])
    fixture.hook().record("EMPTY", parameters: [:])
    fixture.drain()

    XCTAssertEqual(
      fixture.sink.posts.map { $0.inputJSON },
      [
        "{\"name\":\"USER_LOGIN\",\"source\":\"analytics\",\"policy\":{\"mode\":\"allow_list\",\"allowedKeys\":[\"method\"]},"
          + "\"parameters\":{\"map\":[[\"email\",null],[\"method\",\"email\"]]}}",
        "{\"name\":\"EMPTY\",\"source\":\"analytics\",\"policy\":{\"mode\":\"allow_all\"}}",
      ])
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
    // A progress wait, not a speed bound: CI runners stall for seconds.
    wait(for: [done], timeout: 30)
    fixture.drain()

    XCTAssertEqual(fixture.sink.posts.compactMap { $0.input["name"] as? String }, (0..<50).map { "e\($0)" })
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
    // A progress wait, not a speed bound: CI runners stall for seconds.
    wait(for: [done], timeout: 30)
    XCTAssertEqual(threads.current, [false, false])
  }
}

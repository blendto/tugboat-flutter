import Foundation
import XCTest

@testable import Tugboat

/// `TugboatNetworkCall`: one post per call, times from the host clock on the
/// calling thread, and no-op tokens when nothing accepts evidence.
final class NetworkCallTests: XCTestCase {
  func testCompletePostsOneNetworkCallWithBeginAndEndTimes() throws {
    let fixture = EvidenceFixture()
    let call = fixture.begin(method: "GET", route: "/orders/123")
    fixture.clock.set(monoUs: 1_250_000)
    call.complete(statusCode: 200, attemptCount: 2)
    fixture.drain()

    let post = try XCTUnwrap(fixture.sink.posts.first)
    XCTAssertEqual(fixture.sink.posts.count, 1)
    XCTAssertEqual(post.type, "evidence.networkCall")
    XCTAssertEqual(post.at, HostTime(monoUs: 1_250_000, wallUs: 2_000_000), "`at` is the completion time")
    XCTAssertEqual(
      post.inputJSON,
      "{\"method\":\"GET\",\"route\":\"/orders/123\",\"startMonoUs\":1000000,\"endMonoUs\":1250000,"
        + "\"statusCode\":200,\"outcome\":\"response\",\"attemptCount\":2}")
  }

  func testFailOutcomesAndOptionalFields() {
    let fixture = EvidenceFixture()
    fixture.begin().fail(.networkError)
    fixture.begin().fail(.cancelled, statusCode: 499, attemptCount: 0)
    fixture.begin().complete()
    fixture.drain()

    let inputs = fixture.sink.posts.map { $0.input }
    XCTAssertEqual(inputs.map { $0["outcome"] as? String }, ["network_error", "cancelled", "response"])
    XCTAssertNil(inputs[0]["statusCode"])
    XCTAssertNil(inputs[0]["attemptCount"])
    XCTAssertEqual(inputs[1]["statusCode"] as? Int, 499)
    XCTAssertEqual(inputs[1]["attemptCount"] as? Int, 0, "passed through; the engine applies the > 0 rule")
    XCTAssertNil(inputs[2]["statusCode"])
  }

  func testMethodAndRouteArePassedThroughUnchanged() {
    let fixture = EvidenceFixture()
    fixture.begin(method: " get ", route: "/search?q=\"x\"").complete(statusCode: 200)
    fixture.drain()

    let input = fixture.sink.posts.first?.input ?? [:]
    XCTAssertEqual(input["method"] as? String, " get ", "the engine normalizes the method")
    XCTAssertEqual(input["route"] as? String, "/search?q=\"x\"", "the engine validates the route")
  }

  func testASecondCompleteOrFailIsIgnored() {
    let fixture = EvidenceFixture()
    let call = fixture.begin()
    call.complete(statusCode: 200)
    call.complete(statusCode: 500)
    call.fail(.networkError)
    fixture.drain()

    XCTAssertEqual(fixture.sink.posts.count, 1)
    XCTAssertEqual(fixture.sink.posts.first?.input["statusCode"] as? Int, 200)
  }

  func testConcurrentCompletesFromManyThreadsPostOnce() {
    let fixture = EvidenceFixture()
    for _ in 0..<20 {
      let call = fixture.begin()
      DispatchQueue.concurrentPerform(iterations: 16) { index in
        if index.isMultiple(of: 2) {
          call.complete(statusCode: 200 + index)
        } else {
          call.fail(.cancelled)
        }
      }
    }
    fixture.drain()

    XCTAssertEqual(fixture.sink.posts.count, 20, "exactly one post per call")
  }

  func testCallsFromManyThreadsEachPost() {
    let fixture = EvidenceFixture()
    DispatchQueue.concurrentPerform(iterations: 50) { index in
      fixture.begin(route: "/items/\(index)").complete(statusCode: 200)
    }
    fixture.drain()

    let routes = Set(fixture.sink.posts.compactMap { $0.input["route"] as? String })
    XCTAssertEqual(routes, Set((0..<50).map { "/items/\($0)" }))
  }

  func testEmptyOrNilRouteGivesANoOpToken() {
    let fixture = EvidenceFixture()
    fixture.begin(route: "").complete(statusCode: 200)
    fixture.begin(route: nil).fail(.networkError)
    fixture.drain()

    XCTAssertTrue(fixture.sink.posts.isEmpty)
  }

  func testNotStartedGivesANoOpToken() {
    let fixture = EvidenceFixture(open: false)
    let call = fixture.begin()
    fixture.channel.open(fixture.sink)
    call.complete(statusCode: 200)
    fixture.drain()

    XCTAssertTrue(fixture.sink.posts.isEmpty, "a token begun before start stays a no-op")
  }

  func testADisabledHostGivesANoOpToken() {
    let fixture = EvidenceFixture()
    fixture.sink.isRunning = false
    let call = fixture.begin()
    fixture.sink.isRunning = true
    call.complete(statusCode: 200)
    fixture.drain()

    XCTAssertTrue(fixture.sink.posts.isEmpty)
  }

  func testACallFinishedAfterStopOrInTheNextSessionIsDropped() {
    let fixture = EvidenceFixture()
    let stopped = fixture.begin(route: "/stopped")
    let stale = fixture.begin(route: "/stale")
    fixture.channel.close()
    stopped.complete(statusCode: 200)
    fixture.channel.open(fixture.sink)
    stale.complete(statusCode: 200)
    fixture.begin(route: "/fresh").complete(statusCode: 200)
    fixture.drain()

    XCTAssertEqual(fixture.sink.posts.compactMap { $0.input["route"] as? String }, ["/fresh"])
  }

  func testAPostScheduledBeforeStopIsDroppedWhenStopRunsFirst() {
    let fixture = EvidenceFixture()
    let call = fixture.begin()
    fixture.hop.suspend()
    call.complete(statusCode: 200)
    fixture.channel.close()
    fixture.hop.resume()
    fixture.drain()

    XCTAssertTrue(fixture.sink.posts.isEmpty, "the main-thread check sees the closed session")
  }

  func testTheHostStoppingAfterCompleteDropsThePost() {
    let fixture = EvidenceFixture()
    let call = fixture.begin()
    fixture.hop.suspend()
    call.complete(statusCode: 200)
    fixture.sink.isRunning = false
    fixture.hop.resume()
    fixture.drain()

    XCTAssertTrue(fixture.sink.posts.isEmpty)
  }

  func testTimeIsTakenOnTheCallingThreadNotAtTheHop() {
    let fixture = EvidenceFixture()
    let call = fixture.begin()
    fixture.hop.suspend()
    fixture.clock.set(monoUs: 1_100_000)
    call.complete(statusCode: 204)
    fixture.clock.set(monoUs: 9_000_000)
    fixture.hop.resume()
    fixture.drain()

    XCTAssertEqual(fixture.sink.posts.first?.at.monoUs, 1_100_000)
    XCTAssertEqual(fixture.sink.posts.first?.input["endMonoUs"] as? Int, 1_100_000)
  }
}

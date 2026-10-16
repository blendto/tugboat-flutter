#if canImport(UIKit)
import Foundation
import XCTest

@testable import Tugboat

/// `Tugboat.data(for:session:delegate:route:)` and the public
/// `Tugboat.instrumentedSession`, on the shared evidence channel (tapped).
final class DataHelperTests: XCTestCase {
  private var sink: RecordingEvidenceSink!
  private var restore: (() -> Void)?

  override func setUp() {
    super.setUp()
    sink = RecordingEvidenceSink()
    restore = EvidenceChannel.shared.tap(sink)
  }

  override func tearDown() {
    restore?()
    super.tearDown()
  }

  private func request(_ path: String) -> URLRequest {
    var request = URLRequest(url: URL(string: "https://api.example.test" + path + "?token=s3cr3t")!)
    request.setValue("Bearer s3cr3t", forHTTPHeaderField: "Authorization")
    return request
  }

  /// The posts once `count` arrived (they hop to the main thread), after a
  /// short wait for any extra one.
  private func posts(_ count: Int) async throws -> [RecordingEvidenceSink.Post] {
    for _ in 0..<500 where sink.posts.count < count {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    try await Task.sleep(nanoseconds: 200_000_000)
    return sink.posts
  }

  func testTheHelperRecordsTheCallWithItsErrorBody() async throws {
    let body = "{\"error\":\"order_not_found\"}"
    NetworkStubProtocol.reset(["/orders/123": .ok(404, "application/json", body)])
    let session = URLSession(configuration: NetworkStubProtocol.configuration())

    let (data, response) = try await Tugboat.data(for: request("/orders/123"), session: session, route: " /orders/123 ")

    XCTAssertEqual(String(decoding: data, as: UTF8.self), body, "the data is URLSession's, untouched")
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
    let posts = try await posts(1)
    XCTAssertEqual(posts.count, 1)
    let input = try XCTUnwrap(posts.first?.input)
    XCTAssertEqual(input["route"] as? String, "/orders/123")
    XCTAssertEqual(input["method"] as? String, "GET")
    XCTAssertEqual(input["statusCode"] as? Int, 404)
    XCTAssertEqual(input["errorResponseBody"] as? NSDictionary, ["jsonText": body])
    XCTAssertFalse(posts.first?.inputJSON.contains("s3cr3t") ?? true)
  }

  func testOnAnInstrumentedSessionTheCallIsRecordedOnce() async throws {
    NetworkStubProtocol.reset(["/orders/123": .ok(500, "text/plain", "down")])
    let resolved = LockedBox(0)
    let session = Tugboat.instrumentedSession(configuration: NetworkStubProtocol.configuration()) { request in
      resolved.update { $0 += 1 }
      return request.url?.path
    }

    _ = try await Tugboat.data(for: request("/orders/123"), session: session, route: "/orders/{id}")

    let posts = try await posts(1)
    XCTAssertEqual(posts.count, 1, "the helper records it; the session leaves it alone")
    XCTAssertEqual(posts.first?.input["route"] as? String, "/orders/{id}")
    XCTAssertEqual(posts.first?.input["errorResponseBody"] as? NSDictionary, ["value": "down"])
    XCTAssertEqual(resolved.read(), 0)
    session.finishTasksAndInvalidate()
  }

  func testAnInstrumentedSessionRecordsADelegateTask() async throws {
    NetworkStubProtocol.reset(["/orders/123": .ok(409, "application/json", "{\"e\":1}")])
    let completed = expectation(description: "completed")
    let delegate = RecordingSessionDelegate(completed: completed)
    let session = Tugboat.instrumentedSession(
      configuration: NetworkStubProtocol.configuration(), delegate: delegate
    ) { $0.url?.path }

    session.dataTask(with: request("/orders/123")).resume()
    await fulfillment(of: [completed], timeout: 10)

    let posts = try await posts(1)
    XCTAssertEqual(posts.count, 1)
    XCTAssertEqual(posts.first?.input["errorResponseBody"] as? NSDictionary, ["jsonText": "{\"e\":1}"])
    XCTAssertEqual(String(decoding: delegate.snapshot.data, as: UTF8.self), "{\"e\":1}")
    session.finishTasksAndInvalidate()
  }

  func testAnErrorIsRecordedAndRethrownUnchanged() async throws {
    NetworkStubProtocol.reset(["/orders/123": .failure(.notConnectedToInternet)])
    let session = URLSession(configuration: NetworkStubProtocol.configuration())

    do {
      _ = try await Tugboat.data(for: request("/orders/123"), session: session, route: "/orders/123")
      XCTFail("expected the URLSession error")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .notConnectedToInternet)
    }
    let posts = try await posts(1)
    XCTAssertEqual(posts.first?.input["outcome"] as? String, "network_error")
  }

  func testCancellingTheSwiftTaskRecordsCancelled() async throws {
    NetworkStubProtocol.reset(["/orders/123": .hang])
    let session = URLSession(configuration: NetworkStubProtocol.configuration())
    let request = request("/orders/123")

    let call = Task { try await Tugboat.data(for: request, session: session, route: "/orders/123") }
    try await Task.sleep(nanoseconds: 200_000_000)
    call.cancel()
    _ = await call.result

    let posts = try await posts(1)
    XCTAssertEqual(posts.count, 1)
    XCTAssertEqual(posts.first?.input["outcome"] as? String, "cancelled")
  }

  func testTheAppsTaskDelegateStillAnswersTheChallenge() async throws {
    NetworkStubProtocol.reset(["/orders/123": .challenge(then: .ok(200))])
    let session = URLSession(configuration: NetworkStubProtocol.configuration())
    let delegate = RecordingSessionDelegate(completed: XCTestExpectation())

    let (_, response) = try await Tugboat.data(
      for: request("/orders/123"), session: session, delegate: delegate, route: "/orders/123")

    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "the app's credential was used")
    XCTAssertTrue(delegate.snapshot.calls.contains("didReceiveChallenge"))
    XCTAssertEqual(try await posts(1).first?.input["statusCode"] as? Int, 200)
  }

  func testANilRouteRecordsNothing() async throws {
    NetworkStubProtocol.reset(["/orders/123": .ok(200)])
    let session = URLSession(configuration: NetworkStubProtocol.configuration())
    _ = try await Tugboat.data(for: request("/orders/123"), session: session, route: "  ")
    XCTAssertEqual(try await posts(0).count, 0)
  }
}
#endif

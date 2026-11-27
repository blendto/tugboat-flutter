import Alamofire
import Foundation
import XCTest

@_spi(TugboatAdapters) import Tugboat
import TugboatAlamofire

/// `TugboatAlamofireMonitor` on a real Alamofire `Session` answered by
/// `AlamofireStubProtocol`, with Tugboat's evidence tapped: the input the
/// engine would receive for each logical request.
final class TugboatAlamofireMonitorTests: XCTestCase {
  private let base = "https://api.example.test"
  private var tap: TugboatEvidenceTap?
  private let posts = Locked<[(type: String, input: String)]>([])
  private let resolved = Locked(0)

  override func setUp() {
    super.setUp()
    let posts = self.posts
    tap = TugboatAdapters.tapEvidenceForTesting { type, input in
      posts.update { $0.append((type, input)) }
    }
  }

  override func tearDown() {
    tap?.close()
    super.tearDown()
  }

  // MARK: - Helpers

  private func session(
    interceptor: RequestInterceptor? = nil, route: ((URLRequest) throws -> String?)? = nil
  ) -> (Session, TugboatAlamofireMonitor) {
    let configuration = URLSessionConfiguration.af.default
    configuration.protocolClasses = [AlamofireStubProtocol.self]
    let resolved = self.resolved
    let monitor = TugboatAlamofireMonitor { request in
      resolved.update { $0 += 1 }
      if let route = route { return try route(request) }
      return request.url?.path
    }
    return (Session(configuration: configuration, interceptor: interceptor, eventMonitors: [monitor]), monitor)
  }

  private func url(_ path: String) -> String {
    base + path + "?token=s3cr3t-query"
  }

  private let headers: HTTPHeaders = ["Authorization": "Bearer s3cr3t-header"]

  /// Runs `request` to its response and returns it.
  @discardableResult
  private func respond(_ request: DataRequest) -> AFDataResponse<Data?> {
    let done = expectation(description: "response")
    let response = Locked<AFDataResponse<Data?>?>(nil)
    request.response { result in
      response.update { $0 = result }
      done.fulfill()
    }
    wait(for: [done], timeout: 10)
    return response.read()!
  }

  /// The recorded inputs once `count` arrived (they hop to the main
  /// thread), after a short wait for any extra one.
  private func inputs(_ count: Int) -> [[String: Any]] {
    let posts = self.posts
    let arrived = expectation(for: NSPredicate { _, _ in posts.read().count >= count }, evaluatedWith: nil)
    wait(for: [arrived], timeout: 5)
    let settle = expectation(description: "settle")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
    wait(for: [settle], timeout: 2)
    return posts.read().map { post in
      XCTAssertEqual(post.type, "evidence.networkCall")
      XCTAssertFalse(post.input.contains("s3cr3t"), "leaked: \(post.input)")
      XCTAssertFalse(post.input.contains("api.example.test"), "leaked the host: \(post.input)")
      return (try? JSONSerialization.jsonObject(with: Data(post.input.utf8))) as? [String: Any] ?? [:]
    }
  }

  // MARK: - Outcomes

  func test200IsOneResponseWithOneAttempt() throws {
    AlamofireStubProtocol.reset(["/orders/123": [.http(200, "application/json", "{\"id\":1}")]])
    let (session, _) = self.session()
    let response = respond(
      session.request(url("/orders/123"), method: .post, parameters: ["password": "s3cr3t-body"],
        encoding: JSONEncoding.default, headers: headers))

    XCTAssertEqual(response.data.map { String(decoding: $0, as: UTF8.self) }, "{\"id\":1}")
    let inputs = self.inputs(1)
    XCTAssertEqual(inputs.count, 1)
    let input = try XCTUnwrap(inputs.first)
    XCTAssertEqual(input["method"] as? String, "POST")
    XCTAssertEqual(input["route"] as? String, "/orders/123")
    XCTAssertEqual(input["statusCode"] as? Int, 200)
    XCTAssertEqual(input["outcome"] as? String, "response")
    XCTAssertEqual(input["attemptCount"] as? Int, 1)
    XCTAssertNil(input["errorResponseBody"])
    XCTAssertLessThanOrEqual(try XCTUnwrap(input["startMonoUs"] as? Int), try XCTUnwrap(input["endMonoUs"] as? Int))
  }

  func test404WithAJSONBodyIsJSONTextAndTheAppGetsTheBody() {
    let body = "{\"error\":\"order_not_found\"}"
    AlamofireStubProtocol.reset(["/orders/123": [.http(404, "application/json; charset=utf-8", body)]])
    let (session, _) = self.session()
    let response = respond(session.request(url("/orders/123"), headers: headers).validate())

    XCTAssertEqual(response.data.map { String(decoding: $0, as: UTF8.self) }, body)
    let input = inputs(1).first ?? [:]
    XCTAssertEqual(input["statusCode"] as? Int, 404)
    XCTAssertEqual(input["outcome"] as? String, "response", "a validation failure still has a response")
    XCTAssertEqual(input["errorResponseBody"] as? NSDictionary, ["jsonText": body])
  }

  func test500WithATextBodyIsText() {
    AlamofireStubProtocol.reset(["/orders/123": [.http(500, "text/plain", "upstream exploded")]])
    // (text/json would be JSON text, as in Dio: HTTPErrorBodyTests.)
    let (session, _) = self.session()
    respond(session.request(url("/orders/123")))

    let input = inputs(1).first ?? [:]
    XCTAssertEqual(input["statusCode"] as? Int, 500)
    XCTAssertEqual(input["errorResponseBody"] as? NSDictionary, ["value": "upstream exploded"])
  }

  func testAJSONBodyOver64KiBIsTextAndTheAppGetsEveryByte() throws {
    let body = "{\"items\":[" + String(repeating: "1,", count: 40_000) + "0]}"
    AlamofireStubProtocol.reset(["/orders/123": [.http(500, "application/json", body)]])
    let (session, _) = self.session()
    let response = respond(session.request(url("/orders/123")))

    XCTAssertEqual(response.data, Data(body.utf8))
    let text = try XCTUnwrap((inputs(1).first?["errorResponseBody"] as? [String: Any])?["value"] as? String)
    // Cut to whole characters within 4100 bytes, then (as every text body)
    // to 4097 UTF-16 units: both past the engine's 4096-byte cut.
    XCTAssertEqual(text, String(body.prefix(4097)))
  }

  func testATimeoutIsANetworkError() {
    AlamofireStubProtocol.reset(["/orders/123": [.failure(.timedOut)]])
    let (session, _) = self.session()
    respond(session.request(url("/orders/123")))

    let input = inputs(1).first ?? [:]
    XCTAssertEqual(input["outcome"] as? String, "network_error")
    XCTAssertNil(input["statusCode"])
    XCTAssertEqual(input["attemptCount"] as? Int, 1)
  }

  func testACancelledRequestIsCancelled() {
    AlamofireStubProtocol.reset(["/orders/123": [.hang]])
    let (session, _) = self.session()
    let request = session.request(url("/orders/123"))
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { request.cancel() }
    respond(request)

    let inputs = self.inputs(1)
    XCTAssertEqual(inputs.count, 1)
    XCTAssertEqual(inputs.first?["outcome"] as? String, "cancelled")
  }

  func testARedirectIsOneEvent() {
    AlamofireStubProtocol.reset([
      "/orders/123": [.redirect(location: "/v2/orders/123")],
      "/v2/orders/123": [.http(200)],
    ])
    let (session, _) = self.session()
    respond(session.request(url("/orders/123")))

    let inputs = self.inputs(1)
    XCTAssertEqual(inputs.count, 1)
    XCTAssertEqual(inputs.first?["route"] as? String, "/orders/123")
    XCTAssertEqual(inputs.first?["statusCode"] as? Int, 200)
    XCTAssertEqual(resolved.read(), 1)
  }

  // MARK: - Retries

  func testARetriedRequestIsOneEventWithItsAttemptCount() {
    AlamofireStubProtocol.reset(["/orders/123": [.http(503, "text/plain", "busy"), .http(200)]])
    let (session, _) = self.session(interceptor: retryOnce())
    let response = respond(session.request(url("/orders/123")).validate())

    XCTAssertEqual(response.response?.statusCode, 200)
    XCTAssertEqual(AlamofireStubProtocol.received.count, 2)
    let inputs = self.inputs(1)
    XCTAssertEqual(inputs.count, 1, "one logical request")
    XCTAssertEqual(inputs.first?["statusCode"] as? Int, 200)
    XCTAssertEqual(inputs.first?["attemptCount"] as? Int, 2)
    XCTAssertNil(inputs.first?["errorResponseBody"])
    XCTAssertEqual(resolved.read(), 1, "the resolver runs once per request")
  }

  func testRetriesThatRunOutRecordTheLastResponse() {
    AlamofireStubProtocol.reset(["/orders/123": [.http(503, "text/plain", "busy")]])
    let (session, _) = self.session(interceptor: retryOnce())
    respond(session.request(url("/orders/123")).validate())

    let inputs = self.inputs(1)
    XCTAssertEqual(inputs.count, 1)
    XCTAssertEqual(inputs.first?["statusCode"] as? Int, 503)
    XCTAssertEqual(inputs.first?["attemptCount"] as? Int, 2)
    XCTAssertEqual(inputs.first?["errorResponseBody"] as? NSDictionary, ["value": "busy"])
  }

  // MARK: - Resolver and admission

  func testANilEmptyOrThrowingRouteRecordsNothing() {
    AlamofireStubProtocol.reset(["/orders/123": [.http(200)]])
    struct Failure: Error {}
    for route in [{ _ in nil }, { _ in " \u{FEFF} " }, { _ in throw Failure() }] as [(URLRequest) throws -> String?] {
      let (session, _) = self.session(route: route)
      respond(session.request(url("/orders/123")))
    }
    XCTAssertEqual(inputs(0).count, 0)
    XCTAssertEqual(resolved.read(), 3)
  }

  func testNothingRunsWhileTugboatIsNotAcceptingEvidence() {
    tap?.close()
    tap = nil
    AlamofireStubProtocol.reset(["/orders/123": [.http(500, "text/plain", "x")]])
    let (session, _) = self.session()
    let response = respond(session.request(url("/orders/123")))

    XCTAssertEqual(response.data.map { String(decoding: $0, as: UTF8.self) }, "x")
    XCTAssertEqual(resolved.read(), 0, "the resolver never runs")
  }
}

/// Retries a request once when its response was a 503.
private func retryOnce() -> Retrier {
  Retrier { request, _, _, completion in
    completion(request.retryCount == 0 && request.response?.statusCode == 503 ? .retry : .doNotRetry)
  }
}

/// A value behind a lock.
final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) {
    self.value = value
  }

  func read() -> Value {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func update(_ body: (inout Value) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    body(&value)
  }
}

#if canImport(ObjectiveC)
import Foundation
import XCTest

@testable import Tugboat

/// `InstrumentedSessionDelegate` and `NetworkTaskRecorder` on a real
/// `URLSession` answered by `NetworkStubProtocol`: one `network_call` per
/// task, the error-body rule, and the app's delegate getting every
/// callback and every byte unchanged.
final class InstrumentedSessionTests: XCTestCase {
  private let base = "https://api.example.test"
  private var fixture: EvidenceFixture!
  private var resolved: LockedBox<[URLRequest]>!

  override func setUp() {
    super.setUp()
    fixture = EvidenceFixture()
    resolved = LockedBox([])
  }

  // MARK: - Helpers

  /// An instrumented session over the stub whose resolver returns the
  /// path, or `route` when given.
  private func session(
    delegate: URLSessionDelegate?, route: ((URLRequest) throws -> String?)? = nil, fixture: EvidenceFixture? = nil
  ) -> URLSession {
    let resolved = self.resolved!
    let resolver: TugboatRouteResolver = { request in
      resolved.update { $0.append(request) }
      if let route = route { return try route(request) }
      return request.url?.path
    }
    let recorder = NetworkTaskRecorder(routeResolver: resolver, channel: (fixture ?? self.fixture).channel)
    return URLSession(
      configuration: NetworkStubProtocol.configuration(),
      delegate: InstrumentedSessionDelegate(wrapping: delegate, recorder: recorder), delegateQueue: nil)
  }

  private func request(_ path: String, method: String = "GET") -> URLRequest {
    var request = URLRequest(url: URL(string: base + path + "?token=s3cr3t-query")!)
    request.httpMethod = method
    request.setValue("Bearer s3cr3t-header", forHTTPHeaderField: "Authorization")
    if method == "POST" {
      request.httpBody = Data("{\"password\":\"s3cr3t-body\"}".utf8)
    }
    return request
  }

  /// Runs one delegate-based data task to completion.
  @discardableResult
  private func run(
    _ request: URLRequest, on session: URLSession, delegate: RecordingSessionDelegate,
    cancelAfter: TimeInterval? = nil
  ) -> RecordingSessionDelegate.Snapshot {
    let task = session.dataTask(with: request)
    task.resume()
    if let delay = cancelAfter {
      DispatchQueue.global().asyncAfter(deadline: .now() + delay) { task.cancel() }
    }
    wait(for: [delegate.completed], timeout: 10)
    return delegate.snapshot
  }

  /// The posts once `count` arrived, after a short wait for any extra one.
  private func posts(_ count: Int, fixture: EvidenceFixture? = nil) -> [RecordingEvidenceSink.Post] {
    let fixture = fixture ?? self.fixture!
    let deadline = Date().addingTimeInterval(5)
    while fixture.sink.posts.count < count && Date() < deadline {
      fixture.drain()
      Thread.sleep(forTimeInterval: 0.01)
    }
    Thread.sleep(forTimeInterval: 0.2)
    fixture.drain()
    return fixture.sink.posts
  }

  private func appDelegate() -> RecordingSessionDelegate {
    RecordingSessionDelegate(completed: expectation(description: "task completed"))
  }

  private func assertNoSecrets(_ post: RecordingEvidenceSink.Post, file: StaticString = #filePath, line: UInt = #line) {
    for secret in ["s3cr3t", "token", "Authorization", "Bearer", "password", "api.example.test", "https"] {
      XCTAssertFalse(post.inputJSON.contains(secret), "\(secret) leaked: \(post.inputJSON)", file: file, line: line)
    }
  }

  // MARK: - Outcomes

  func test200RecordsTheResponseAndNoQueryHeaderOrBody() throws {
    NetworkStubProtocol.reset(["/orders/123": .ok(200, "application/json", "{\"id\":123}")])
    let delegate = appDelegate()
    let snapshot = run(request("/orders/123", method: "POST"), on: session(delegate: delegate), delegate: delegate)

    let posts = self.posts(1)
    XCTAssertEqual(posts.count, 1)
    let post = try XCTUnwrap(posts.first)
    XCTAssertEqual(post.type, "evidence.networkCall")
    let input = post.input
    XCTAssertEqual(input["method"] as? String, "POST")
    XCTAssertEqual(input["route"] as? String, "/orders/123")
    XCTAssertEqual(input["statusCode"] as? Int, 200)
    XCTAssertEqual(input["outcome"] as? String, "response")
    XCTAssertNil(input["errorResponseBody"], "below 400 the body is never read")
    XCTAssertNil(input["attemptCount"])
    let start = try XCTUnwrap(input["startMonoUs"] as? Int)
    let end = try XCTUnwrap(input["endMonoUs"] as? Int)
    XCTAssertLessThanOrEqual(start, end)
    XCTAssertEqual(end, 1_000_000, "the event is placed at the host clock")
    assertNoSecrets(post)
    XCTAssertEqual(Set(input.keys), ["method", "route", "startMonoUs", "endMonoUs", "statusCode", "outcome"])
    XCTAssertEqual(String(decoding: snapshot.data, as: UTF8.self), "{\"id\":123}")
    XCTAssertEqual(
      snapshot.calls, ["didReceiveResponse", "didReceiveData", "didFinishCollecting", "didComplete"])
  }

  func test404WithAJSONBodySendsTheWholeBodyAsJSONText() throws {
    let body = "{\"error\":\"order_not_found\",\"detail\":\"no order 123\"}"
    NetworkStubProtocol.reset([
      "/orders/123": .http(status: 404, contentType: "Application/JSON; charset=utf-8", body: Data(body.utf8), chunk: 7)
    ])
    let delegate = appDelegate()
    let snapshot = run(request("/orders/123"), on: session(delegate: delegate), delegate: delegate)

    let post = try XCTUnwrap(posts(1).first)
    XCTAssertEqual(post.input["errorResponseBody"] as? NSDictionary, ["jsonText": body])
    XCTAssertEqual(String(decoding: snapshot.data, as: UTF8.self), body, "the app gets the whole body")
    assertNoSecrets(post)

    let data = try XCTUnwrap(try ConformanceEngine.record(type: post.type, inputJSON: post.inputJSON, atMonoUs: 1_000_000))
    XCTAssertEqual(data["errorResponseBody"] as? NSDictionary, ["error": "order_not_found", "detail": "no order 123"])
    XCTAssertEqual(
      data["errorResponseBodyCapture"] as? NSDictionary, ["format": "json", "representation": "native", "truncated": false])
  }

  func test500WithATextBodySendsText() throws {
    NetworkStubProtocol.reset(["/orders/123": .ok(500, "text/plain", "upstream exploded")])
    let delegate = appDelegate()
    run(request("/orders/123"), on: session(delegate: delegate), delegate: delegate)

    let post = try XCTUnwrap(posts(1).first)
    XCTAssertEqual(post.input["statusCode"] as? Int, 500)
    XCTAssertEqual(post.input["errorResponseBody"] as? NSDictionary, ["value": "upstream exploded"])
    let data = try XCTUnwrap(try ConformanceEngine.record(type: post.type, inputJSON: post.inputJSON, atMonoUs: 1_000_000))
    XCTAssertEqual(data["errorResponseBody"] as? String, "upstream exploded")
    XCTAssertEqual((data["errorResponseBodyCapture"] as? [String: Any])?["format"] as? String, "text")
  }

  func testAJSONBodyOver64KiBFallsBackToTextAndTheAppGetsEveryByte() throws {
    let body = "{\"items\":[" + String(repeating: "\"é\",", count: 20_000) + "\"end\"]}"
    let bytes = Data(body.utf8)
    XCTAssertGreaterThan(bytes.count, HTTPErrorBody.completeBytes)
    NetworkStubProtocol.reset([
      "/orders/123": .http(status: 422, contentType: "application/problem+json", body: bytes, chunk: 4093)
    ])
    let delegate = appDelegate()
    let snapshot = run(request("/orders/123"), on: session(delegate: delegate), delegate: delegate)

    XCTAssertEqual(snapshot.data, bytes, "the app's delegate gets the full, intact body")
    let post = try XCTUnwrap(posts(1).first)
    let text = try XCTUnwrap((post.input["errorResponseBody"] as? [String: Any])?["value"] as? String)
    XCTAssertEqual(text, HTTPErrorBody.text(bytes))
    XCTAssertTrue(body.hasPrefix(text))
    XCTAssertLessThanOrEqual(text.utf8.count, HTTPErrorBody.textBytes)
    XCTAssertGreaterThan(text.utf8.count, 4096)
    let data = try XCTUnwrap(try ConformanceEngine.record(type: post.type, inputJSON: post.inputJSON, atMonoUs: 1_000_000))
    XCTAssertEqual(
      data["errorResponseBodyCapture"] as? NSDictionary, ["format": "text", "representation": "native", "truncated": true])
  }

  func testATimeoutIsANetworkError() throws {
    NetworkStubProtocol.reset(["/orders/123": .failure(.timedOut)])
    let delegate = appDelegate()
    let snapshot = run(request("/orders/123"), on: session(delegate: delegate), delegate: delegate)

    XCTAssertEqual(snapshot.errorCodes, [URLError.timedOut.rawValue])
    let post = try XCTUnwrap(posts(1).first)
    XCTAssertEqual(post.input["outcome"] as? String, "network_error")
    XCTAssertNil(post.input["statusCode"])
    XCTAssertFalse(post.inputJSON.contains("timed out"), "no transport error text")
  }

  func testACancelledTaskIsCancelled() throws {
    NetworkStubProtocol.reset(["/orders/123": .hang])
    let delegate = appDelegate()
    let snapshot = run(request("/orders/123"), on: session(delegate: delegate), delegate: delegate, cancelAfter: 0.2)

    XCTAssertEqual(snapshot.errorCodes, [URLError.cancelled.rawValue])
    let posts = self.posts(1)
    XCTAssertEqual(posts.count, 1)
    XCTAssertEqual(posts.first?.input["outcome"] as? String, "cancelled")
  }

  func testARedirectIsOneEventForTheOriginalRequest() throws {
    NetworkStubProtocol.reset([
      "/orders/123": .redirect(location: "/v2/orders/123"),
      "/v2/orders/123": .ok(404, "application/json", "{\"error\":\"moved_and_gone\"}"),
    ])
    let delegate = appDelegate()
    let snapshot = run(request("/orders/123"), on: session(delegate: delegate), delegate: delegate)

    XCTAssertTrue(snapshot.calls.contains("willPerformHTTPRedirection"), "the app decides the redirect")
    XCTAssertEqual(NetworkStubProtocol.received.map { $0.url?.path }, ["/orders/123", "/v2/orders/123"])
    let posts = self.posts(1)
    XCTAssertEqual(posts.count, 1, "a redirect stays inside one call")
    XCTAssertEqual(posts.first?.input["route"] as? String, "/orders/123", "the route of the app's request")
    XCTAssertEqual(posts.first?.input["statusCode"] as? Int, 404)
    XCTAssertEqual(posts.first?.input["errorResponseBody"] as? NSDictionary, ["jsonText": "{\"error\":\"moved_and_gone\"}"])
    XCTAssertEqual(resolved.read().count, 1, "the resolver runs once per call")
  }

  func testAnAuthChallengeGoesToTheAppAndTheTaskIsOneEvent() throws {
    NetworkStubProtocol.reset(["/orders/123": .challenge(then: .ok(200, "application/json", "{\"ok\":true}"))])
    let delegate = appDelegate()
    let snapshot = run(request("/orders/123"), on: session(delegate: delegate), delegate: delegate)

    XCTAssertTrue(snapshot.calls.contains("didReceiveChallenge"), "the app's delegate answers the challenge: \(snapshot.calls)")
    XCTAssertEqual(snapshot.statusCodes, [200])
    let posts = self.posts(1)
    XCTAssertEqual(posts.count, 1)
    XCTAssertEqual(posts.first?.input["statusCode"] as? Int, 200)
  }

  // MARK: - Delegate forwarding

  func testTheAppDelegateGetsTheSameCallbacksAndBytesAsWithoutInstrumentation() {
    let body = Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    NetworkStubProtocol.reset([
      "/orders/123": .http(status: 503, contentType: "application/octet-stream", body: body, chunk: 3000)
    ])
    let plainDelegate = appDelegate()
    let plain = URLSession(configuration: NetworkStubProtocol.configuration(), delegate: plainDelegate, delegateQueue: nil)
    let expected = run(request("/orders/123"), on: plain, delegate: plainDelegate)

    let delegate = appDelegate()
    let observed = run(request("/orders/123"), on: session(delegate: delegate), delegate: delegate)

    XCTAssertEqual(observed, expected)
    XCTAssertEqual(observed.data, body)
    let received = NetworkStubProtocol.received
    XCTAssertEqual(received.count, 2)
    XCTAssertEqual(received.first?.allHTTPHeaderFields, received.last?.allHTTPHeaderFields, "headers unchanged")
    XCTAssertEqual(received.first?.url, received.last?.url)
    XCTAssertEqual(posts(1).count, 1)
  }

  func testTheProxyRespondsToExactlyTheAppDelegatesMethodsPlusItsObservers() {
    let recorder = NetworkTaskRecorder(routeResolver: { _ in "/x" }, channel: fixture.channel)
    let withApp = InstrumentedSessionDelegate(
      wrapping: RecordingSessionDelegate(completed: XCTestExpectation(description: "unused")), recorder: recorder)
    let alone = InstrumentedSessionDelegate(wrapping: nil, recorder: recorder)
    // The Objective-C names URLSession asks about.
    let challenge = NSSelectorFromString("URLSession:task:didReceiveChallenge:completionHandler:")
    let sessionChallenge = NSSelectorFromString("URLSession:didReceiveChallenge:completionHandler:")
    let redirect = NSSelectorFromString("URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:")
    let response = NSSelectorFromString("URLSession:dataTask:didReceiveResponse:completionHandler:")
    let download = NSSelectorFromString("URLSession:downloadTask:didFinishDownloadingToURL:")
    let background = NSSelectorFromString("URLSessionDidFinishEventsForBackgroundURLSession:")
    let observed = [
      NSSelectorFromString("URLSession:dataTask:didReceiveData:"),
      NSSelectorFromString("URLSession:task:didFinishCollectingMetrics:"),
      NSSelectorFromString("URLSession:task:didCompleteWithError:"),
    ]

    for selector in [challenge, redirect, response] {
      XCTAssertTrue(withApp.responds(to: selector), "\(selector) is forwarded")
      XCTAssertFalse(alone.responds(to: selector), "\(selector) is not claimed without an app delegate")
    }
    for selector in [sessionChallenge, download, background] {
      XCTAssertFalse(withApp.responds(to: selector), "\(selector): the app's delegate does not implement it")
    }
    for selector in observed {
      XCTAssertTrue(alone.responds(to: selector))
    }
    XCTAssertTrue(withApp.conforms(to: URLSessionDataDelegate.self))
  }

  func testAForwardedChallengeReturnsTheAppsDisposition() {
    let recorder = NetworkTaskRecorder(routeResolver: { _ in "/x" }, channel: fixture.channel)
    let app = RecordingSessionDelegate(completed: XCTestExpectation(description: "unused"))
    let proxy: URLSessionTaskDelegate = InstrumentedSessionDelegate(wrapping: app, recorder: recorder)
    let session = URLSession(configuration: .ephemeral)
    let task = session.dataTask(with: URL(string: base + "/x")!)
    let space = URLProtectionSpace(
      host: "api.example.test", port: 443, protocol: "https", realm: "r",
      authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
    let challenge = URLAuthenticationChallenge(
      protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil,
      sender: NetworkStubProtocol(request: URLRequest(url: URL(string: base)!), cachedResponse: nil, client: nil))
    let answered = LockedBox<(URLSession.AuthChallengeDisposition, String?)?>(nil)
    proxy.urlSession?(
      session, task: task, didReceive: challenge,
      completionHandler: { disposition, credential in
        answered.update { $0 = (disposition, credential?.user) }
      })
    XCTAssertEqual(answered.read()?.0, .useCredential)
    XCTAssertEqual(answered.read()?.1, "user")
    XCTAssertEqual(app.snapshot.calls, ["didReceiveChallenge"])
    session.invalidateAndCancel()
  }

  // MARK: - Tasks the delegate sees less of

  func testACompletionHandlerTaskIsRecordedWithoutABody() throws {
    NetworkStubProtocol.reset(["/orders/123": .ok(404, "application/json", "{\"error\":\"x\"}")])
    let done = expectation(description: "completion handler")
    let received = LockedBox(Data())
    let task = session(delegate: nil).dataTask(with: request("/orders/123")) { data, _, _ in
      received.update { $0 = data ?? Data() }
      done.fulfill()
    }
    task.resume()
    wait(for: [done], timeout: 10)

    XCTAssertEqual(String(decoding: received.read(), as: UTF8.self), "{\"error\":\"x\"}")
    let posts = self.posts(1)
    XCTAssertEqual(posts.count, 1)
    XCTAssertEqual(posts.first?.input["statusCode"] as? Int, 404)
    XCTAssertNil(posts.first?.input["errorResponseBody"], "the delegate never sees a completion handler's body")
  }

  // MARK: - Resolver and admission

  func testANilEmptyOrThrowingRouteRecordsNothing() {
    NetworkStubProtocol.reset(["/orders/123": .ok(200)])
    struct ResolverFailure: Error {}
    let routes: [(URLRequest) throws -> String?] = [{ _ in nil }, { _ in " \u{FEFF}\t" }, { _ in throw ResolverFailure() }]
    for route in routes {
      let delegate = appDelegate()
      run(request("/orders/123"), on: session(delegate: delegate, route: route), delegate: delegate)
    }
    XCTAssertEqual(posts(0).count, 0)
    XCTAssertEqual(resolved.read().count, 3)
  }

  func testTheRouteIsTrimmedAsDartTrims() {
    NetworkStubProtocol.reset(["/orders/123": .ok(200)])
    let delegate = appDelegate()
    run(
      request("/orders/123"), on: session(delegate: delegate, route: { _ in "\u{3000} /orders/{id}\u{FEFF}\n" }),
      delegate: delegate)
    XCTAssertEqual(posts(1).first?.input["route"] as? String, "/orders/{id}")
  }

  func testNothingIsReadWhileTugboatIsNotAcceptingEvidence() {
    NetworkStubProtocol.reset(["/orders/123": .ok(500, "text/plain", "x")])
    let closed = EvidenceFixture(open: false)
    let delegate = appDelegate()
    let snapshot = run(request("/orders/123"), on: session(delegate: delegate, fixture: closed), delegate: delegate)

    XCTAssertEqual(String(decoding: snapshot.data, as: UTF8.self), "x")
    XCTAssertEqual(posts(0, fixture: closed).count, 0)
    XCTAssertEqual(resolved.read().count, 0, "the resolver never runs")
  }
}
#endif

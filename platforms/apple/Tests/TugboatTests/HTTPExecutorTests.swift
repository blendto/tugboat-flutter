import Foundation
import XCTest

@testable import Tugboat

/// `HTTPExecutor` over a real `URLSession` whose requests `StubURLProtocol`
/// answers.
final class HTTPExecutorTests: XCTestCase {
  private let frames = FrameHandleTable()
  private var executor: HTTPExecutor!

  override func setUp() {
    super.setUp()
    StubURLProtocol.reset { _ in .response(status: 202, headers: [:], body: Data("{\"sessionId\":\"s-1\"}".utf8)) }
    executor = makeExecutor(baseURL: "http://127.0.0.1:3000/")
  }

  override func tearDown() {
    executor.close()
    executor = nil
    super.tearDown()
  }

  private func makeExecutor(baseURL: String) -> HTTPExecutor {
    let configuration = HTTPExecutor.makeSessionConfiguration()
    configuration.protocolClasses = [StubURLProtocol.self]
    let frames = self.frames
    return HTTPExecutor(
      config: HostConfig(
        collectorBaseURL: baseURL, apiKey: "pmk_key", appVersion: "1.2.3", appBuild: "42", appId: "com.example.app"),
      frameBytes: { frames.get($0) },
      sessionConfiguration: configuration)
  }

  private func json(_ body: String, path: String = "/v1/sessions", timeoutMs: Int = 5_000) -> HTTPRequest {
    HTTPRequest(requestId: "http-1", lane: "lifecycle", path: path, timeoutMs: timeoutMs, body: .json(body))
  }

  /// Sends `request` and waits for its single answer.
  private func perform(_ request: HTTPRequest, on executor: HTTPExecutor? = nil, timeout: TimeInterval = 5)
    -> TransportOutcome?
  {
    let answered = expectation(description: "answered")
    let outcome = Locked<TransportOutcome?>(nil)
    let target: HTTPExecutor = executor ?? self.executor
    target.send(request) { result in
      outcome.withLock { $0 = result }
      answered.fulfill()
    }
    wait(for: [answered], timeout: timeout)
    return outcome.current
  }

  func testJSONRequestsCarryTheFlutterHeadersAndTheExactBody() {
    let body = "{\"events\":[{\"w\":390.0,\"s\":\"é/\\u2028\"}]}"
    XCTAssertEqual(
      perform(json(body, path: "/v1/events/batch")), .http(status: 202, body: "{\"sessionId\":\"s-1\"}"))

    XCTAssertEqual(StubURLProtocol.received.count, 1)
    guard let request = StubURLProtocol.received.first else { return }
    XCTAssertEqual(request.request.httpMethod, "POST")
    XCTAssertEqual(request.request.url?.absoluteString, "http://127.0.0.1:3000/v1/events/batch")
    XCTAssertEqual(request.body, Data(body.utf8), "sent byte for byte")
    let expected = [
      "X-PMKit-API-Key": "pmk_key",
      "X-Tugboat-API-Key": "pmk_key",
      "X-Platform": "ios",
      "X-App-Build": "42",
      "X-App-Version": "1.2.3",
      "X-App-Id": "com.example.app",
      "X-Sdk-Version": TugboatVersion.current,
      "Content-Type": "application/json; charset=utf-8",
    ]
    for (name, value) in expected {
      XCTAssertEqual(request.header(name), value, name)
    }
  }

  func testStatusAndBodyPassThroughForRejections() {
    StubURLProtocol.reset { _ in .response(status: 400, headers: [:], body: Data("{\"error\":\"bad\"}".utf8)) }
    XCTAssertEqual(perform(json("{}")), .http(status: 400, body: "{\"error\":\"bad\"}"))
  }

  func testRedirectsAreReportedNotFollowed() {
    StubURLProtocol.reset { request in
      request.url?.path == "/elsewhere"
        ? .response(status: 202, headers: [:], body: Data())
        : .redirect(status: 302, location: "/elsewhere")
    }
    let outcome = perform(json("{}", timeoutMs: 2_000))
    guard case let .http(status, _)? = outcome else {
      return XCTFail("expected the 302, got \(String(describing: outcome))")
    }
    XCTAssertEqual(status, 302)
    XCTAssertEqual(StubURLProtocol.received.count, 1)
  }

  func testTheDelegateRefusesRedirects() {
    let delegate = HTTPSessionDelegate()
    guard let url = URL(string: "http://127.0.0.1:3000/v1/sessions"),
      let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: nil)
    else {
      return XCTFail("fixture")
    }
    let task = URLSession.shared.dataTask(with: url)
    var followed: URLRequest? = URLRequest(url: url)
    delegate.urlSession(
      URLSession.shared, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: url)
    ) { followed = $0 }
    XCTAssertNil(followed)
    task.cancel()
  }

  func testBodiesAreTruncatedTo64KiB() {
    StubURLProtocol.reset { _ in
      .response(status: 202, headers: [:], body: Data(String(repeating: "x", count: 100 * 1024).utf8))
    }
    guard case let .http(status, body)? = perform(json("{}")) else {
      return XCTFail("expected an HTTP outcome")
    }
    XCTAssertEqual(status, 202)
    XCTAssertEqual(body.utf8.count, CollectorResponse.maxBodyBytes)
  }

  func testTruncationNeverSplitsACharacter() {
    let kept = String(repeating: "x", count: CollectorResponse.maxBodyBytes - 1)
    StubURLProtocol.reset { _ in .response(status: 202, headers: [:], body: Data((kept + "😀 and more").utf8)) }
    XCTAssertEqual(perform(json("{}")), .http(status: 202, body: kept))
  }

  func testStatusesTheEngineWouldRejectAreErrors() {
    StubURLProtocol.reset { _ in .response(status: 600, headers: [:], body: Data("odd".utf8)) }
    XCTAssertEqual(perform(json("{}")), .error)
  }

  func testMultipartMatchesTheFlutterFrameUpload() {
    let first = Data([0xFF, 0xD8, 1, 2])
    let second = Data([0xFF, 0xD8, 3])
    let request = HTTPRequest(
      requestId: "http-1", lane: "frames", path: "/v1/frames", timeoutMs: 15_000,
      body: .multipart(
        fields: [
          FormField(name: "sessionId", value: "s-1"),
          FormField(name: "frameNos", value: "1,2"),
          FormField(name: "frameMetadata", value: "[{\"frameNo\":1},{\"frameNo\":2}]"),
        ],
        frames: [
          FramePart(handle: frames.put(first), filename: "1.jpg"),
          FramePart(handle: frames.put(second), filename: "2.jpg"),
        ]))

    XCTAssertEqual(perform(request), .http(status: 202, body: "{\"sessionId\":\"s-1\"}"))
    guard let upload = StubURLProtocol.received.first, let contentType = upload.header("Content-Type") else {
      return XCTFail("no upload")
    }
    XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="), contentType)
    let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
    guard let parts = MultipartPart.parse(upload.body, boundary: boundary) else {
      return XCTFail("unparseable multipart body")
    }

    XCTAssertEqual(parts.map { $0.name }, ["sessionId", "frameNos", "frameMetadata", "files", "files"])
    XCTAssertEqual(parts.map { $0.filename }, [nil, nil, nil, "1.jpg", "2.jpg"])
    XCTAssertEqual(parts.prefix(3).map { $0.text }, ["s-1", "1,2", "[{\"frameNo\":1},{\"frameNo\":2}]"])
    XCTAssertEqual(parts.count, 5)
    if parts.count == 5 {
      XCTAssertEqual(parts[3].contentType, "image/jpeg")
      XCTAssertEqual(parts[3].bytes, first)
      XCTAssertEqual(parts[4].bytes, second)
    }
  }

  func testAReleasedFrameFailsTheRequestWithoutSendingIt() {
    let handle = frames.put(Data([1]))
    frames.release(handle)
    let request = HTTPRequest(
      requestId: "http-1", lane: "frames", path: "/v1/frames", timeoutMs: 1_000,
      body: .multipart(
        fields: [FormField(name: "sessionId", value: "s")], frames: [FramePart(handle: handle, filename: "1.jpg")]))

    XCTAssertEqual(perform(request), .error)
    XCTAssertTrue(StubURLProtocol.received.isEmpty)
  }

  func testRequestsTimeOutAtTheTotalDeadline() {
    StubURLProtocol.reset { _ in .hang }
    let start = Date()
    XCTAssertEqual(perform(json("{}", timeoutMs: 200)), .timeout)
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertGreaterThanOrEqual(elapsed, 0.19)
    XCTAssertLessThan(elapsed, 2)
  }

  func testTransportTimeoutsAreTimeouts() {
    StubURLProtocol.reset { _ in .failure(.timedOut) }
    XCTAssertEqual(perform(json("{}")), .timeout)
  }

  func testConnectionFailuresAreErrors() {
    StubURLProtocol.reset { _ in .failure(.cannotConnectToHost) }
    XCTAssertEqual(perform(json("{}")), .error)
  }

  func testMalformedBaseURLsAreErrors() {
    for baseURL in ["not a url", "ftp://127.0.0.1", ""] {
      let broken = makeExecutor(baseURL: baseURL)
      XCTAssertEqual(perform(json("{}"), on: broken), .error, baseURL)
      broken.close()
    }
    XCTAssertTrue(StubURLProtocol.received.isEmpty)
  }

  func testPathsResolveAgainstTheBaseURLLikeDart() {
    XCTAssertEqual(
      HTTPExecutor.resolve(baseURL: "https://collector.example///", path: "/v1/frames")?.absoluteString,
      "https://collector.example/v1/frames")
    XCTAssertEqual(
      HTTPExecutor.resolve(baseURL: "http://10.0.2.2:3000", path: "/v1/sessions")?.absoluteString,
      "http://10.0.2.2:3000/v1/sessions")
  }

  func testSendAfterCloseAnswersError() {
    executor.close()
    XCTAssertEqual(perform(json("{}")), .error)
    XCTAssertTrue(StubURLProtocol.received.isEmpty)
  }

  func testCloseLetsARunningRequestAnswerOnce() {
    StubURLProtocol.reset { _ in .hang }
    let answered = expectation(description: "answered once")
    let outcome = Locked<TransportOutcome?>(nil)
    executor.send(json("{}", timeoutMs: 300)) { result in
      outcome.withLock { $0 = result }
      answered.fulfill()
    }
    let deadline = Date().addingTimeInterval(2)
    while StubURLProtocol.received.isEmpty && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    executor.close()
    wait(for: [answered], timeout: 3)
    XCTAssertEqual(outcome.current, .timeout)
  }

  func testAnswersComeFromTheIOQueueExactlyOnce() {
    let answered = expectation(description: "answered")
    answered.assertForOverFulfill = true
    let onMain = Locked<Bool?>(nil)
    executor.send(json("{}")) { _ in
      onMain.withLock { $0 = Thread.isMainThread }
      answered.fulfill()
    }
    wait(for: [answered], timeout: 5)
    // Give a duplicate answer time to show up as an over-fulfilment.
    let settle = expectation(description: "settle")
    settle.isInverted = true
    wait(for: [settle], timeout: 0.3)
    XCTAssertEqual(onMain.current, false)
  }
}

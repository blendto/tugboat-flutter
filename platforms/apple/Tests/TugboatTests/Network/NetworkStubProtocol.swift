#if canImport(ObjectiveC)
import Foundation

@testable import Tugboat

/// A test-only `URLProtocol` that answers the requests of a session
/// configured with it (the shipped helper never uses one). Each reply is
/// chosen by path; bodies are delivered in chunks, so a delegate sees more
/// than one `didReceive data`.
final class NetworkStubProtocol: URLProtocol, URLAuthenticationChallengeSender {
  enum Reply {
    case response(status: Int, headers: [String: String], body: Data, chunk: Int)
    case failure(URLError.Code)
    /// A 302 to `location`; the session follows it with a new request.
    case redirect(location: String)
    /// An HTTP Basic challenge: a credential gets `then`, anything else a 401.
    indirect case challenge(then: Reply)
    /// Never answers; only cancellation ends the request.
    case hang

    static func ok(_ status: Int, _ contentType: String? = nil, _ body: String = "") -> Reply {
      http(status: status, contentType: contentType, body: Data(body.utf8))
    }

    static func http(status: Int, contentType: String?, body: Data, chunk: Int = 1000) -> Reply {
      .response(
        status: status, headers: contentType.map { ["Content-Type": $0] } ?? [:], body: body, chunk: chunk)
    }
  }

  private struct State {
    var replies: [String: Reply] = [:]
    var received: [URLRequest] = []
  }

  private static let state = Locked(State())

  /// Replies by URL path; unknown paths get a 404 without a body.
  static func reset(_ replies: [String: Reply]) {
    state.withLock { $0 = State(replies: replies, received: []) }
  }

  static var received: [URLRequest] {
    state.current.received
  }

  /// A configuration whose requests this protocol answers.
  static func configuration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NetworkStubProtocol.self]
    return configuration
  }

  private var pendingAfterChallenge: Reply?

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let request = self.request
    let reply = NetworkStubProtocol.state.withLock { (state: inout State) -> Reply in
      state.received.append(request)
      return state.replies[request.url?.path ?? ""] ?? .ok(404)
    }
    answer(reply)
  }

  override func stopLoading() {}

  private func answer(_ reply: Reply) {
    guard let client = client, let url = request.url else { return }
    switch reply {
    case let .response(status, headers, body, chunk):
      guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
      else { return }
      client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      var offset = 0
      while offset < body.count {
        let end = min(offset + max(1, chunk), body.count)
        client.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
        offset = end
      }
      client.urlProtocolDidFinishLoading(self)
    case let .failure(code):
      client.urlProtocol(self, didFailWithError: URLError(code))
    case let .redirect(location):
      guard
        let response = HTTPURLResponse(
          url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": location]),
        let target = URL(string: location, relativeTo: url)
      else { return }
      client.urlProtocol(self, wasRedirectedTo: URLRequest(url: target.absoluteURL), redirectResponse: response)
    case let .challenge(then):
      pendingAfterChallenge = then
      let space = URLProtectionSpace(
        host: url.host ?? "", port: url.port ?? 443, protocol: url.scheme, realm: "stub",
        authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
      let failure = HTTPURLResponse(
        url: url, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: ["WWW-Authenticate": "Basic realm=\"stub\""])
      client.urlProtocol(
        self,
        didReceive: URLAuthenticationChallenge(
          protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: failure,
          error: nil, sender: self))
    case .hang:
      break
    }
  }

  // MARK: - URLAuthenticationChallengeSender

  func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {
    answer(pendingAfterChallenge ?? .ok(200))
  }

  func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {
    answer(.ok(401))
  }

  func cancel(_ challenge: URLAuthenticationChallenge) {
    answer(.failure(.userCancelledAuthentication))
  }

  func performDefaultHandling(for challenge: URLAuthenticationChallenge) {
    answer(.ok(401))
  }

  func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {
    answer(.ok(401))
  }
}
#endif

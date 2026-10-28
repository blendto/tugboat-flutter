import Foundation

@testable import Tugboat

/// A `URLProtocol` that answers every request of a session configured with
/// it, and records what it received.
final class StubURLProtocol: URLProtocol {
  enum Reply {
    case response(status: Int, headers: [String: String], body: Data)
    case failure(URLError.Code)
    case redirect(status: Int, location: String)
    /// Never answers; only cancellation ends the request.
    case hang
  }

  struct Received {
    let request: URLRequest
    let body: Data

    func header(_ name: String) -> String? {
      request.value(forHTTPHeaderField: name)
    }
  }

  private struct State {
    var reply: (URLRequest) -> Reply = { _ in .response(status: 202, headers: [:], body: Data()) }
    var received: [Received] = []
  }

  private static let state = Locked(State())

  static func reset(reply: @escaping (URLRequest) -> Reply) {
    state.withLock { $0 = State(reply: reply, received: []) }
  }

  static var received: [Received] {
    state.current.received
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let request = self.request
    let received = Received(request: request, body: StubURLProtocol.body(of: request))
    let reply = StubURLProtocol.state.withLock { (state: inout State) -> Reply in
      state.received.append(received)
      return state.reply(request)
    }
    guard let client = client, let url = request.url else { return }
    switch reply {
    case let .response(status, headers, body):
      guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
      else { return }
      client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client.urlProtocol(self, didLoad: body)
      client.urlProtocolDidFinishLoading(self)
    case let .failure(code):
      client.urlProtocol(self, didFailWithError: URLError(code))
    case let .redirect(status, location):
      guard
        let response = HTTPURLResponse(
          url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": location]),
        let target = URL(string: location, relativeTo: url)
      else { return }
      client.urlProtocol(self, wasRedirectedTo: URLRequest(url: target.absoluteURL), redirectResponse: response)
      // When the session refuses the redirect, the 3xx is the final response.
      client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client.urlProtocolDidFinishLoading(self)
    case .hang:
      break
    }
  }

  override func stopLoading() {}

  /// URLSession hands a protocol the body as a stream, not `httpBody`.
  private static func body(of request: URLRequest) -> Data {
    if let body = request.httpBody {
      return body
    }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      let read = stream.read(&buffer, maxLength: buffer.count)
      if read <= 0 {
        break
      }
      data.append(buffer, count: read)
    }
    return data
  }
}

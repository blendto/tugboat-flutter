import Foundation

/// A test-only `URLProtocol` answering an Alamofire session's requests by
/// path. A path's replies are used in turn (the last one repeats), so a
/// retried request can get a different answer.
final class AlamofireStubProtocol: URLProtocol {
  enum Reply {
    case response(status: Int, contentType: String?, body: Data)
    case failure(URLError.Code)
    case redirect(location: String)
    case hang

    static func http(_ status: Int, _ contentType: String? = nil, _ body: String = "") -> Reply {
      .response(status: status, contentType: contentType, body: Data(body.utf8))
    }
  }

  private static let lock = NSLock()
  private static var replies: [String: [Reply]] = [:]
  private static var receivedRequests: [URLRequest] = []

  static func reset(_ newReplies: [String: [Reply]]) {
    lock.lock()
    defer { lock.unlock() }
    replies = newReplies
    receivedRequests = []
  }

  static var received: [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return receivedRequests
  }

  private static func next(for request: URLRequest) -> Reply {
    lock.lock()
    defer { lock.unlock() }
    receivedRequests.append(request)
    let path = request.url?.path ?? ""
    guard var queue = replies[path], let first = queue.first else { return .http(404) }
    if queue.count > 1 {
      queue.removeFirst()
      replies[path] = queue
    }
    return first
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let client = client, let url = request.url else { return }
    switch Self.next(for: request) {
    case let .response(status, contentType, body):
      let headers = contentType.map { ["Content-Type": $0] } ?? [:]
      guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
      else { return }
      client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      var offset = 0
      while offset < body.count {
        let end = min(offset + 2048, body.count)
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
    case .hang:
      break
    }
  }

  override func stopLoading() {}
}

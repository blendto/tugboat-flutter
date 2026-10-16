#if canImport(ObjectiveC)
import Foundation
import XCTest

/// An app's own session delegate: records every callback it gets and the
/// data, follows redirects, answers challenges with a credential, and
/// allows responses.
final class RecordingSessionDelegate: NSObject, URLSessionDataDelegate {
  struct Snapshot: Equatable {
    var calls: [String] = []
    var data = Data()
    var statusCodes: [Int] = []
    var errorCodes: [Int] = []
  }

  private let state = LockedBox(Snapshot())
  let completed: XCTestExpectation

  init(completed: XCTestExpectation) {
    self.completed = completed
  }

  var snapshot: Snapshot { state.read() }

  private func note(_ call: String) {
    state.update { $0.calls.append(call) }
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    note("didReceiveResponse")
    if let http = response as? HTTPURLResponse {
      state.update { $0.statusCodes.append(http.statusCode) }
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    state.update {
      if $0.calls.last != "didReceiveData" { $0.calls.append("didReceiveData") }
      $0.data.append(data)
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    note("willPerformHTTPRedirection")
    completionHandler(request)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    note("didReceiveChallenge")
    completionHandler(.useCredential, URLCredential(user: "user", password: "secret", persistence: .none))
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
    note("didFinishCollecting")
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error = error as? URLError {
      state.update { $0.errorCodes.append(error.code.rawValue) }
    }
    note("didComplete")
    completed.fulfill()
  }
}

/// A value behind a lock, for delegate callbacks on the session's queue.
final class LockedBox<Value> {
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
#endif

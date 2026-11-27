import Foundation

/// Forwards `URLSession` callbacks to its executor. The session retains its
/// delegate until it is invalidated, so the delegate holds the executor
/// weakly. Callbacks run on the executor's IO queue (the session's delegate
/// queue). `executor` is set once, before the session can call back, which is
/// why the unchecked `Sendable` is sound.
final class HTTPSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  weak var executor: HTTPExecutor?

  /// POST redirects are reported, never followed (dart:io does the same):
  /// the task completes with the 3xx response.
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    executor?.received(response: response, taskId: task.taskIdentifier)
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    executor?.received(response: response, taskId: dataTask.taskIdentifier)
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    executor?.received(data: data, taskId: dataTask.taskIdentifier)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    executor?.completed(taskId: task.taskIdentifier, error: error)
  }
}

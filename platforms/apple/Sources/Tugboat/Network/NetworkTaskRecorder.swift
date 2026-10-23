#if canImport(ObjectiveC)
import Foundation
import ObjectiveC

/// Turns one instrumented session's task callbacks into `network_call`
/// evidence: one event per task, which is one logical request (redirects
/// and URLSession's own authentication retries happen inside it).
///
/// - Recorded once, at the first of: metrics for a task that is already
///   completed, or `didCompleteWithError`. Tasks made with a completion
///   handler (and `async` `data(for:)`) never call `didCompleteWithError`
///   on the session delegate, but still deliver metrics.
/// - Timing: the task's own duration from its metrics (the first
///   transaction's `fetchStartDate`, or the task's start when it never
///   fetched, to the end of `taskInterval`), placed before the host clock
///   reading at the moment the call is recorded. Without metrics the
///   duration is 0.
/// - Outcome: `URLError.cancelled` is `cancelled`; any other error is
///   `network_error` (with the status code if a response arrived); no error
///   is `response` with the status code.
/// - Error body, for a status of 400 or more: the bytes delegate-based
///   data tasks delivered through `didReceive data`, at most 65,537 of them
///   (section 4.5 of evidence-messages.md). Other tasks have none.
/// - Not recorded: stream and WebSocket tasks, tasks made by
///   `Tugboat.data(for:session:delegate:route:)` (it records them), tasks
///   whose route resolver returns nil or empty or throws, and anything
///   while Tugboat is not accepting evidence.
///
/// Callable on any queue; per-task state lives on the task (an associated
/// object) and is guarded by one lock.
final class NetworkTaskRecorder: @unchecked Sendable {
  /// Per-task state, released with the task.
  private final class TaskState {
    var errorBody = Data()
    var durationUs: Int64?
    var recorded = false
  }

  private static var stateKey: UInt8 = 0

  private let routeResolver: TugboatRouteResolver
  private let channel: EvidenceChannel
  private let lock = NSLock()

  init(routeResolver: @escaping TugboatRouteResolver, channel: EvidenceChannel = .shared) {
    self.routeResolver = routeResolver
    self.channel = channel
  }

  func task(_ task: URLSessionDataTask, didReceive data: Data) {
    guard let status = (task.response as? HTTPURLResponse)?.statusCode, status >= 400,
      channel.admit() != nil, !Self.isRecordedByHelper(task)
    else { return }
    withState(of: task) { state in
      guard !state.recorded else { return }
      let room = HTTPErrorBody.peekBytes - state.errorBody.count
      if room > 0 {
        state.errorBody.append(data.prefix(room))
      }
    }
  }

  func task(_ task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
    let durationUs = Self.durationUs(metrics)
    let completed = task.state == .completed
    withState(of: task) { $0.durationUs = durationUs }
    if completed {
      record(task, error: task.error)
    }
  }

  func task(_ task: URLSessionTask, didCompleteWithError error: Error?) {
    record(task, error: error)
  }

  // MARK: - Recording

  private func record(_ task: URLSessionTask, error: Error?) {
    guard let (errorBody, durationUs) = takeForRecording(task) else { return }
    guard Self.isRecordable(task), channel.admit() != nil, let request = task.originalRequest,
      let route = NetworkRoute.resolve(routeResolver, request)
    else { return }
    let call = TugboatNetworkCall.begin(
      method: NetworkRoute.method(request), route: route, channel: channel, startedBeforeNowUs: durationUs)
    NetworkOutcome.finish(call, response: task.response, error: error) {
      HTTPErrorBody.body(bytes: errorBody, contentType: NetworkOutcome.contentType(of: task.response))
    }
  }

  /// Marks the task recorded and hands over its body and duration; nil
  /// when it was recorded already.
  private func takeForRecording(_ task: URLSessionTask) -> (Data, Int64)? {
    withState(of: task) { state -> (Data, Int64)? in
      guard !state.recorded else { return nil }
      state.recorded = true
      defer { state.errorBody = Data() }
      return (state.errorBody, state.durationUs ?? 0)
    }
  }

  private func withState<Result>(of task: URLSessionTask, _ body: (TaskState) -> Result) -> Result {
    lock.lock()
    defer { lock.unlock() }
    let state: TaskState
    if let existing = objc_getAssociatedObject(task, &Self.stateKey) as? TaskState {
      state = existing
    } else {
      state = TaskState()
      objc_setAssociatedObject(task, &Self.stateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    return body(state)
  }

  /// Request/response tasks only: not stream or WebSocket tasks, nor a
  /// task the helper records itself.
  private static func isRecordable(_ task: URLSessionTask) -> Bool {
    if task is URLSessionStreamTask {
      return false
    }
    if #available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *), task is URLSessionWebSocketTask {
      return false
    }
    return !isRecordedByHelper(task)
  }

  static func isRecordedByHelper(_ task: URLSessionTask) -> Bool {
    if #available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *) {
      return task.delegate is RecordedByHelperTaskDelegate
    }
    return false
  }

  /// The task's duration in microseconds: from its first transaction's
  /// fetch start (the task's start if it never fetched) to its end.
  static func durationUs(_ metrics: URLSessionTaskMetrics) -> Int64 {
    let interval = metrics.taskInterval
    let start = metrics.transactionMetrics.first?.fetchStartDate ?? interval.start
    let seconds = interval.end.timeIntervalSince(start)
    guard seconds.isFinite, seconds > 0 else { return 0 }
    return Int64(min(seconds, 86_400 * 2) * 1_000_000)
  }
}

/// How an observed request ended, mapped as `tugboat_dio` maps Dio's.
enum NetworkOutcome {
  /// `cancelled` for a cancellation; `network_error` for any other error
  /// (keeping the status code of a response that arrived); otherwise
  /// `response` with the status code, and `errorBody()` when it is 400 or
  /// more (it is not evaluated otherwise).
  static func finish(
    _ call: TugboatNetworkCall, response: URLResponse?, error: Error?, attemptCount: Int? = nil,
    errorBody: () -> Any?
  ) {
    let statusCode = (response as? HTTPURLResponse)?.statusCode
    if let error = error {
      if isCancellation(error) {
        call.fail(.cancelled, attemptCount: attemptCount)
      } else {
        call.fail(.networkError, statusCode: statusCode, attemptCount: attemptCount)
      }
      return
    }
    let body = call.isRecording && (statusCode ?? 0) >= 400 ? errorBody() : nil
    call.complete(statusCode: statusCode, attemptCount: attemptCount, errorResponseBody: body)
  }

  static func isCancellation(_ error: Error) -> Bool {
    if #available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *), error is CancellationError {
      return true
    }
    return (error as? URLError)?.code == .cancelled
  }

  /// The response's `Content-Type`, read only to classify an error body.
  static func contentType(of response: URLResponse?) -> String? {
    guard let response = response as? HTTPURLResponse else { return nil }
    for (name, value) in response.allHeaderFields {
      if let name = name as? String, name.caseInsensitiveCompare("Content-Type") == .orderedSame {
        return value as? String
      }
    }
    return nil
  }
}
#endif

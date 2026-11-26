#if canImport(ObjectiveC)
import Foundation

/// The delegate of a session from `Tugboat.instrumentedSession`: the app's
/// delegate behind a `DelegateForwarder`, observing three callbacks.
///
/// - `didReceive data` (delegate-based data tasks only): the recorder keeps
///   a bounded copy of an error response's bytes; the same `Data` is then
///   passed to the app's delegate.
/// - `didFinishCollecting metrics`: the task's own timing.
/// - `didCompleteWithError`: the outcome.
///
/// Each records first (bounded work: the route resolver and one encode),
/// then calls the app's delegate with the same arguments, if it implements
/// the method. Nothing is changed, retried, or re-read.
final class InstrumentedSessionDelegate: DelegateForwarder, URLSessionDataDelegate {
  let recorder: NetworkTaskRecorder

  init(wrapping delegate: URLSessionDelegate?, recorder: NetworkTaskRecorder) {
    self.recorder = recorder
    super.init(target: delegate)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    recorder.task(dataTask, didReceive: data)
    (target as? URLSessionDataDelegate)?.urlSession?(session, dataTask: dataTask, didReceive: data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
    recorder.task(task, didFinishCollecting: metrics)
    (target as? URLSessionTaskDelegate)?.urlSession?(session, task: task, didFinishCollecting: metrics)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    recorder.task(task, didCompleteWithError: error)
    (target as? URLSessionTaskDelegate)?.urlSession?(session, task: task, didCompleteWithError: error)
  }
}

/// The task delegate `Tugboat.data(for:session:delegate:route:)` passes to
/// URLSession: the app's task delegate (if any) behind a
/// `DelegateForwarder`, implementing nothing itself, so URLSession calls
/// exactly what it would have called. An instrumented session sees it on
/// `task.delegate` and leaves the task to the helper, which records it.
final class RecordedByHelperTaskDelegate: DelegateForwarder, URLSessionTaskDelegate {
  init(wrapping delegate: URLSessionTaskDelegate?) {
    super.init(target: delegate)
  }
}
#endif

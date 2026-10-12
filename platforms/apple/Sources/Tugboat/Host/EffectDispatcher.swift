/// Routes each `Effect` to its executor. Runs on the engine queue; answers
/// (`transport.result`) go back through `post`, stamped when they arrive.
final class EffectDispatcher {
  private let timers: TimerExecutor
  private let http: HTTPSender
  private let frames: FrameHandleTable
  private weak var captures: CaptureRequestSink?
  private let post: (_ type: String, _ inputJSON: String) -> Void
  private let log: (String) -> Void
  private var reported = Set<String>()

  init(
    timers: TimerExecutor,
    http: HTTPSender,
    frames: FrameHandleTable,
    captures: CaptureRequestSink? = nil,
    post: @escaping (_ type: String, _ inputJSON: String) -> Void,
    log: @escaping (String) -> Void = HostLog.warning
  ) {
    self.timers = timers
    self.http = http
    self.frames = frames
    self.captures = captures
    self.post = post
    self.log = log
  }

  func dispatch(_ effect: Effect) {
    switch effect {
    case let .timerSchedule(timerId, atMonoUs):
      timers.schedule(timerId: timerId, atMonoUs: atMonoUs)
    case let .timerCancel(timerId):
      timers.cancel(timerId: timerId)
    case let .httpSend(request):
      let post = self.post
      http.send(request) { outcome in
        post(
          HostMessages.transportResult,
          HostMessages.transportResultInput(requestId: request.requestId, outcome: outcome))
      }
    case let .frameRelease(handle):
      frames.release(handle)
    case let .captureRequest(request):
      // Without a sink the engine resolves the request at its C18 answer
      // deadline (`paint_readiness_timeout`).
      guard let captures = captures else {
        if reported.insert("capture.request").inserted {
          log("no capture sink; capture.request left to its answer deadline")
        }
        return
      }
      captures.onCaptureRequest(request)
    case let .unknown(type):
      if reported.insert(type).inserted {
        log("ignoring unknown effect type \(type)")
      }
    }
  }
}

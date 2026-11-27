/// An effect request from an engine response (stateful-engine.md section
/// 3.1), decoded once by `EffectParser`.
enum Effect: Equatable {
  case timerSchedule(timerId: String, atMonoUs: Int64)
  case timerCancel(timerId: String)
  case httpSend(HTTPRequest)
  case frameRelease(handle: String)
  case captureRequest(CaptureRequestEffect)
  /// A type this host does not execute; logged once per type and ignored.
  case unknown(type: String)
}

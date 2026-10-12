/// `input` objects of the messages the host itself sends.
enum HostMessages {
  static let timerFired = "timer.fired"
  static let transportResult = "transport.result"
  /// The last message before the handle is destroyed: the engine reports
  /// undelivered work and becomes inert. Its input is empty.
  static let engineDispose = "engine.dispose"

  static func timerFiredInput(timerId: String) -> String {
    "{\"timerId\":" + JSONText.quoted(timerId) + "}"
  }

  static func transportResultInput(requestId: String, outcome: TransportOutcome) -> String {
    var out = "{\"requestId\":" + JSONText.quoted(requestId)
    switch outcome {
    case let .http(status, body):
      out += ",\"outcome\":\"http\",\"status\":\(status),\"body\":" + JSONText.quoted(body)
    case .error:
      out += ",\"outcome\":\"error\""
    case .timeout:
      out += ",\"outcome\":\"timeout\""
    }
    return out + "}"
  }
}

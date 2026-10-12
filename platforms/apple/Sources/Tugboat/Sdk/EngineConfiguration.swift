/// The `engine.configure` input (stateful-engine.md section 6). Groups the
/// SDK sets explicitly; everything else keeps the engine's Dart defaults.
///
/// - `host`: `HostMetadata`, every field `session_start` needs.
/// - `limits`: the Dart defaults, stated so a changed engine default cannot
///   silently change native sessions.
/// - `gesture`: the SwiftUI adapter's `GestureConfig` in points, so the
///   engine and the adapter's tap check agree.
/// - `capture.answerTimeoutMs`: the C18 deadline for a `capture.result`.
/// - `collector.enabled`: the engine owns delivery; the host only performs
///   `http.send`.
/// - `capabilities`: `focusChanges` from `TugboatConfig`. iOS produces no
///   system input facts, so `systemInput` keeps the engine default (off).
enum EngineConfiguration {
  static let maxEvents: Int64 = 5000
  static let maxFrames: Int64 = 500
  static let maxScrollSamples: Int64 = 200
  static let captureAnswerTimeoutMs: Int64 = 5000

  static func build(config: TugboatConfig, host: HostMetadata, gesture: GestureConfig) -> JSONObject {
    var limits = JSONObject()
    limits.set("maxEvents", maxEvents)
    limits.set("maxFrames", maxFrames)
    limits.set("maxScrollSamples", maxScrollSamples)
    var capture = JSONObject()
    capture.set("answerTimeoutMs", captureAnswerTimeoutMs)
    var collector = JSONObject()
    collector.set("enabled", true)
    var capabilities = JSONObject()
    capabilities.set("focusChanges", config.captureFocusChanges)

    var out = JSONObject()
    out.set("host", host.hostJSON)
    out.set("limits", limits)
    out.set("gesture", gesture.engineJSON)
    out.set("capture", capture)
    out.set("collector", collector)
    out.set("capabilities", capabilities)
    return out
  }
}

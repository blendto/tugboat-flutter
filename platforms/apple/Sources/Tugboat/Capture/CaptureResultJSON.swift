/// Encodes `CaptureAnswer`s as `capture.result` inputs.
///
/// Both backend fields are always `nativeBackend`: the collector's
/// `frameMetadata[].requestedBackend` / `resolvedBackend` are a closed enum
/// (`flutterRepaintBoundary` | `nativeCpuExperimental`), and the native SDKs
/// capture through the native CPU pixel runtime. A new backend name would
/// 400 every frame upload (decisions log).
enum CaptureResultJSON {
  static let nativeBackend = "nativeCpuExperimental"

  /// One day, the engine's bound on every duration.
  private static let maxMicros: Int64 = 86_400_000_000

  static func encode(_ answer: CaptureAnswer, maskCoverage: Bool = EngineVocabulary.frameMaskCoverage) -> String {
    var input = JSONObject()
    input.set("requestId", answer.requestId)
    switch answer {
    case let .captured(_, frame, boundaryRect, timings):
      input.set("outcome", "captured")
      input.set("frame", self.frame(frame, maskCoverage: maskCoverage))
      input.set("boundaryRect", boundaryRect.json)
      input.set("timings", self.timings(timings))
    case let .failed(_, failure, timings):
      input.set("outcome", "failed")
      input.set("failure", failure.rawValue)
      if let timings = timings {
        input.set("timings", self.timings(timings))
      }
    case .cancelled:
      input.set("outcome", "cancelled")
    }
    return input.json
  }

  private static func frame(_ frame: CapturedFrame, maskCoverage: Bool) -> JSONObject {
    var out = JSONObject()
    out.set("handle", frame.handle)
    out.set("width", Int64(frame.width))
    out.set("height", Int64(frame.height))
    out.set("contentHash", frame.contentHash)
    out.set("masked", frame.masked)
    out.set("byteLength", Int64(frame.byteLength))
    out.set("captureMicros", clamp(frame.captureMicros))
    out.set("requestedBackend", nativeBackend)
    out.set("resolvedBackend", nativeBackend)
    if !frame.dHash.isEmpty {
      out.set("dHash", frame.dHash)
    }
    out.set("structureSignature", frame.structureSignature)
    if maskCoverage {
      var coverage = JSONObject()
      coverage.set("mode", frame.maskCoverage.mode)
      coverage.set("reasons", .array(frame.maskCoverage.reasons.map { .string($0) }))
      out.set("maskCoverage", coverage)
    }
    return out
  }

  private static func timings(_ timings: CaptureTimingsMicros) -> JSONObject {
    var out = JSONObject()
    out.set("frameWaitMicros", clamp(timings.frameWaitMicros))
    out.set("readbackMicros", clamp(timings.readbackMicros))
    out.set("maskMicros", clamp(timings.maskMicros))
    out.set("encodeMicros", clamp(timings.encodeMicros))
    return out
  }

  private static func clamp(_ micros: Int64) -> Int64 {
    min(max(micros, 0), maxMicros)
  }
}

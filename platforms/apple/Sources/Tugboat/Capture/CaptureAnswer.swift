/// One `capture.result` (stateful-engine.md section 8.2). Every
/// `capture.request` gets exactly one, by `requestId`.
enum CaptureAnswer: Equatable {
  /// `boundaryRect` is the window size of the draw the frame came from;
  /// nil only when no draw was recorded (the frame is then masked whole).
  case captured(requestId: String, frame: CapturedFrame, boundaryRect: BoundaryRect?, timings: CaptureTimingsMicros)
  case failed(requestId: String, failure: CaptureFailure, timings: CaptureTimingsMicros?)
  case cancelled(requestId: String)

  var requestId: String {
    switch self {
    case let .captured(requestId, _, _, _), let .failed(requestId, _, _), let .cancelled(requestId):
      return requestId
    }
  }

  /// Handles the message hands to the engine; the host releases them if
  /// the engine rejects it.
  var frameHandles: [String] {
    if case let .captured(_, frame, _, _) = self {
      return [frame.handle]
    }
    return []
  }
}

/// A frame in the host's handle table, as the engine's
/// `capture.result.frame`.
struct CapturedFrame: Equatable {
  let handle: String
  /// Encoded JPEG size in pixels.
  let width: Int
  let height: Int
  /// SHA-256 of the JPEG bytes (empty for a perceptual skip).
  let contentHash: String
  /// True when at least one mask rectangle was filled before encoding.
  let masked: Bool
  let byteLength: Int
  let captureMicros: Int64
  let dHash: String
  /// The visible structure the masks were computed from (draw time).
  let structureSignature: String
  /// Which mask mode applied to the drawn frame (sent as
  /// `frame.maskCoverage`; every reason keeps its own name).
  let maskCoverage: MaskCoverage
}

extension MaskCoverage {
  /// A frame the runtime masked whole without a recorded draw.
  static let failClosed = MaskCoverage(mode: .wholeFrame, reasons: [.walkExhausted])
}

/// The capture boundary in window points, at the window's origin.
struct BoundaryRect: Equatable {
  let x: Double
  let y: Double
  let width: Double
  let height: Double

  var json: JSONObject {
    var out = JSONObject()
    out.set("x", .double(x))
    out.set("y", .double(y))
    out.set("width", .double(width))
    out.set("height", .double(height))
    return out
  }
}

/// The `timings` group; it feeds the engine's screenshot budget.
struct CaptureTimingsMicros: Equatable {
  var frameWaitMicros: Int64 = 0
  var readbackMicros: Int64 = 0
  var maskMicros: Int64 = 0
  var encodeMicros: Int64 = 0
}

/// The engine's closed failure vocabulary (Dart `ScreenshotCaptureFailure`)
/// as far as iOS produces it. iOS has no secure-window flag, so
/// `secureWindow` is never sent.
enum CaptureFailure: String {
  case boundaryUnavailable
  case layoutUnavailable
  case paintTimedOut
  case readbackFailed
  case maskFailed
  case encodingFailed
}

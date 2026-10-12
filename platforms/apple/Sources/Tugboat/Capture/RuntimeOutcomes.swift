#if canImport(UIKit)
import Foundation
import TugboatCaptureRuntime

/// What the host knew when it asked the runtime for one capture.
struct InFlightCapture {
  let requestId: String
  /// The supplier, which records each draw's coverage and boundary.
  let masks: FrameMasks
  /// The engine's baseline, offered only to requests that are not forced.
  let offeredBaseline: DHashBaseline?
  let frameWaitMicros: Int64
  let startedNanos: UInt64
}

/// Turns a `TugboatCaptureRuntime` `CaptureResult` into the
/// `capture.result` answer, explicitly per `CaptureStatus`:
///
/// | Runtime status | Answer |
/// | --- | --- |
/// | `ok` with JPEG bytes | `captured` (bytes stored in the handle table) |
/// | `ok` without bytes | `failed encodingFailed` |
/// | `skippedByDHash` | `captured` with the offered baseline's `dHash` and structure (the runtime skips only when the drawn structure equals it; the engine coalesces and releases the empty handle); without a baseline `failed readbackFailed` |
/// | `unsupportedApi`, `surfaceUnavailable`, `unsupportedRenderMode` | `failed boundaryUnavailable` |
/// | `timeout` | `failed paintTimedOut` |
/// | `pixelCopyFailed` | `failed readbackFailed` (nothing visible was drawn) |
/// | `processingFailed` | `failed encodingFailed` |
/// | `cancelled`, `disposed` | `cancelled` |
///
/// A captured frame reports the coverage and boundary of the draw it came
/// from. iOS has no secure-window flag, so `secureWindow` is never answered.
struct RuntimeOutcomes {
  let frames: FrameHandleTable
  let nanoTime: () -> UInt64

  func answer(_ capture: InFlightCapture, _ result: CaptureResult) -> CaptureAnswer {
    switch result.status {
    case .ok:
      return result.jpeg.isEmpty ? failed(capture, result, .encodingFailed) : captured(capture, result)
    case .skippedByDHash:
      return coalesced(capture, result)
    case .unsupportedApi, .surfaceUnavailable, .unsupportedRenderMode:
      return failed(capture, result, .boundaryUnavailable)
    case .timeout:
      return failed(capture, result, .paintTimedOut)
    case .pixelCopyFailed:
      return failed(capture, result, .readbackFailed)
    case .processingFailed:
      return failed(capture, result, .encodingFailed)
    case .cancelled, .disposed:
      return .cancelled(requestId: capture.requestId)
    }
  }

  private func captured(_ capture: InFlightCapture, _ result: CaptureResult) -> CaptureAnswer {
    let handle = frames.put(result.jpeg)
    let frame = Frame(
      handle: handle, byteLength: result.jpeg.count, dHash: result.dHash,
      structureSignature: result.maskSnapshot?.structureSignature ?? "", contentHash: result.contentHash)
    return capturedAnswer(capture, result, frame)
  }

  /// The runtime matched the baseline within its Hamming threshold under
  /// the same structure and encoded nothing. The engine coalesces only when
  /// the reported dHash and structure equal its baseline, so that is what
  /// is reported.
  private func coalesced(_ capture: InFlightCapture, _ result: CaptureResult) -> CaptureAnswer {
    guard let baseline = capture.offeredBaseline else {
      return failed(capture, result, .readbackFailed)
    }
    let frame = Frame(
      handle: frames.put(Data()), byteLength: 0, dHash: baseline.dHash,
      structureSignature: baseline.structureSignature, contentHash: "")
    return capturedAnswer(capture, result, frame)
  }

  /// The parts of a captured frame that differ between a fresh and a
  /// coalesced answer.
  private struct Frame {
    let handle: String
    let byteLength: Int
    let dHash: String
    let structureSignature: String
    let contentHash: String
  }

  private func capturedAnswer(_ capture: InFlightCapture, _ result: CaptureResult, _ parts: Frame) -> CaptureAnswer {
    // Without a recorded draw the runtime masked the frame whole.
    let drawn = capture.masks.drawn(result.maskSnapshot)
    let masked = result.maskSnapshot.map { $0.wholeFrame || !$0.masks.isEmpty } ?? true
    let frame = CapturedFrame(
      handle: parts.handle,
      width: result.width,
      height: result.height,
      contentHash: parts.contentHash,
      masked: masked,
      byteLength: parts.byteLength,
      captureMicros: elapsedMicros(since: capture.startedNanos),
      dHash: parts.dHash,
      structureSignature: parts.structureSignature,
      maskCoverage: drawn?.coverage ?? .failClosed
    )
    return .captured(
      requestId: capture.requestId, frame: frame, boundaryRect: drawn?.geometry.boundaryRect,
      timings: timings(capture, result))
  }

  private func failed(_ capture: InFlightCapture, _ result: CaptureResult, _ failure: CaptureFailure) -> CaptureAnswer {
    .failed(requestId: capture.requestId, failure: failure, timings: timings(capture, result))
  }

  private func timings(_ capture: InFlightCapture, _ result: CaptureResult) -> CaptureTimingsMicros {
    let t = result.timings
    return CaptureTimingsMicros(
      frameWaitMicros: capture.frameWaitMicros,
      readbackMicros: t.surfaceCopyMicros &+ t.pixelReadbackMicros,
      maskMicros: t.maskComputeMicros &+ t.maskFillMicros &+ t.dHashMicros,
      encodeMicros: t.jpegMicros &+ t.sha256Micros
    )
  }

  private func elapsedMicros(since startNanos: UInt64) -> Int64 {
    let now = nanoTime()
    return now > startNanos ? Int64(clamping: (now - startNanos) / 1_000) : 0
  }
}
#endif

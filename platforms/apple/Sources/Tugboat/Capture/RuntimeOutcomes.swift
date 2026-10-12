#if canImport(UIKit)
import Foundation
import TugboatCaptureRuntime

/// What the host knew when it asked the runtime for one capture.
struct InFlightCapture {
  let requestId: String
  /// The window size when the request reached the main thread; the
  /// boundary when the draw never happened.
  let requestGeometry: CaptureGeometry
  /// The supplier, which keeps the boundary of the drawn frame.
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
/// iOS has no secure-window flag, so `secureWindow` is never answered.
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
    let structure = result.maskSnapshot?.structureSignature ?? ""
    return capturedAnswer(
      capture, result, handle: handle, byteLength: result.jpeg.count, dHash: result.dHash,
      structureSignature: structure, contentHash: result.contentHash)
  }

  /// The runtime matched the baseline within its Hamming threshold under
  /// the same structure and encoded nothing. The engine coalesces only when
  /// the reported dHash and structure equal its baseline, so that is what
  /// is reported.
  private func coalesced(_ capture: InFlightCapture, _ result: CaptureResult) -> CaptureAnswer {
    guard let baseline = capture.offeredBaseline else {
      return failed(capture, result, .readbackFailed)
    }
    let handle = frames.put(Data())
    return capturedAnswer(
      capture, result, handle: handle, byteLength: 0, dHash: baseline.dHash,
      structureSignature: baseline.structureSignature, contentHash: "")
  }

  private func capturedAnswer(
    _ capture: InFlightCapture,
    _ result: CaptureResult,
    handle: String,
    byteLength: Int,
    dHash: String,
    structureSignature: String,
    contentHash: String
  ) -> CaptureAnswer {
    // A supplied capture always reports its snapshot; without one the
    // runtime masked the frame whole.
    let snapshot = result.maskSnapshot
    let coverage = snapshot.map(RuntimeOutcomes.wire) ?? .failClosed
    let masked = snapshot.map { $0.wholeFrame || !$0.masks.isEmpty } ?? true
    let frame = CapturedFrame(
      handle: handle,
      width: result.width,
      height: result.height,
      contentHash: contentHash,
      masked: masked,
      byteLength: byteLength,
      captureMicros: elapsedMicros(since: capture.startedNanos),
      dHash: dHash,
      structureSignature: structureSignature,
      maskCoverage: coverage
    )
    let boundary = (capture.masks.geometry ?? capture.requestGeometry).boundaryRect
    return .captured(requestId: capture.requestId, frame: frame, boundaryRect: boundary, timings: timings(capture, result))
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

  private static func wire(_ snapshot: MaskSnapshot) -> WireMaskCoverage {
    guard let coverage = snapshot.coverage else { return .failClosed }
    switch coverage.mode {
    case .precise: return WireMaskCoverage(mode: "precise", reasons: coverage.reasons)
    case .wholeHost: return WireMaskCoverage(mode: "wholeHost", reasons: coverage.reasons)
    case .wholeFrame: return WireMaskCoverage(mode: "wholeFrame", reasons: coverage.reasons)
    }
  }
}
#endif

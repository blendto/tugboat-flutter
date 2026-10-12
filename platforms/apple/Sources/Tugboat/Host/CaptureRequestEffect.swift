/// The fields of a `capture.request` effect the host acts on
/// (stateful-engine.md section 8.2). The others are the engine's own
/// bookkeeping: it already waited out `notBeforeMonoUs` and applied
/// `dropWhenBusy`, and it checks `context` itself when the answer arrives.
struct CaptureRequestEffect: Equatable {
  /// `capture-N`; the `capture.result` echoes it.
  let requestId: String
  /// Capture even when the paint is unchanged.
  let force: Bool
  /// The frame must be painted after the request.
  let requireFreshPaint: Bool
  /// Multiplies the capture pixel ratio (the engine's `degradedScale` under
  /// budget pressure); always in (0, 1].
  let scale: Double
  let dHashBaseline: DHashBaseline?

  /// A forced or fresh-paint request must get a freshly encoded frame: it is
  /// never offered the baseline, so the pixel runtime cannot skip it and the
  /// host never answers `paintUnchanged`.
  var offeredBaseline: DHashBaseline? {
    force || requireFreshPaint ? nil : dHashBaseline
  }
}

/// The perceptual baseline the engine offers: the last accepted frame's
/// dHash and the visible structure it was captured with. Opaque tokens.
struct DHashBaseline: Equatable {
  let dHash: String
  let structureSignature: String
}

/// Performs `capture.request` effects. Called on the engine queue; it must
/// return at once and answer every request exactly once, by id, with a
/// `capture.result` (C16: requests may overlap, in any order).
protocol CaptureRequestSink: AnyObject {
  func onCaptureRequest(_ request: CaptureRequestEffect)
}

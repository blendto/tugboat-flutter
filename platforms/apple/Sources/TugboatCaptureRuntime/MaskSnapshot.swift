import Foundation

/// The masks for the frame a view capture is about to draw, from the
/// caller's mask supplier (`CaptureRuntime.capture(view:request:maskSupplier:onComplete:)`).
///
/// The runtime reads `masks` and `wholeFrame`. `structureSignature` and
/// `coverage` are the caller's own description of the frame: the runtime
/// compares the signature with `CaptureRequest.lastStructureSignature`
/// before it may skip by dHash, and passes the snapshot back in
/// `CaptureResult.maskSnapshot`.
public struct MaskSnapshot {
  /// Normalized to the captured view's bounds.
  public let masks: [NormalizedMask]
  /// Mask the whole frame: the caller could not describe it with confidence.
  public let wholeFrame: Bool
  /// The caller's opaque visible-structure token.
  public let structureSignature: String
  public let coverage: MaskCoverageSummary?

  public init(
    masks: [NormalizedMask],
    wholeFrame: Bool = false,
    structureSignature: String = "",
    coverage: MaskCoverageSummary? = nil
  ) {
    self.masks = masks
    self.wholeFrame = wholeFrame
    self.structureSignature = structureSignature
    self.coverage = coverage
  }

  /// Everything masked: what a supplied capture uses when no snapshot was
  /// taken for the drawn frame.
  public static var failClosed: MaskSnapshot {
    MaskSnapshot(
      masks: [NormalizedMask(x: 0, y: 0, width: 1, height: 1)],
      wholeFrame: true,
      coverage: MaskCoverageSummary(mode: .wholeFrame)
    )
  }
}

/// How precisely a frame's masks follow its content, and why not more.
public struct MaskCoverageSummary {
  public let mode: MaskCoverageMode
  /// Reason names from the caller's closed vocabulary.
  public let reasons: [String]

  public init(mode: MaskCoverageMode, reasons: [String] = []) {
    self.mode = mode
    self.reasons = reasons
  }
}

public enum MaskCoverageMode {
  /// Every maskable element has its own rectangle.
  case precise
  /// A toolkit host view is masked whole.
  case wholeHost
  /// The whole frame is masked.
  case wholeFrame
}

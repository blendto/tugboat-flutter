import Foundation

/// The masks for the frame a view capture is about to draw, from the
/// caller's mask supplier (`CaptureRuntime.capture(view:request:maskSupplier:onComplete:)`).
///
/// The runtime reads `masks` and `wholeFrame`, and compares
/// `structureSignature` with `CaptureRequest.lastStructureSignature` before
/// it may skip by dHash. `id` is the caller's own: the runtime passes the
/// snapshot back in `CaptureResult.maskSnapshot` so the caller can tell
/// which draw (of several attempts) the frame came from.
public struct MaskSnapshot {
  /// Normalized to the captured view's bounds.
  public let masks: [NormalizedMask]
  /// Mask the whole frame: the caller could not describe it with confidence.
  public let wholeFrame: Bool
  /// The caller's opaque visible-structure token; empty means unknown, and
  /// an unknown structure never skips by dHash.
  public let structureSignature: String
  /// The caller's id for this snapshot; never read by the runtime.
  public let id: Int

  public init(
    masks: [NormalizedMask],
    wholeFrame: Bool = false,
    structureSignature: String = "",
    id: Int = 0
  ) {
    self.masks = masks
    self.wholeFrame = wholeFrame
    self.structureSignature = structureSignature
    self.id = id
  }

  /// Everything masked: what a supplied capture uses when no snapshot was
  /// taken for the drawn frame.
  public static var failClosed: MaskSnapshot {
    MaskSnapshot(masks: [NormalizedMask(x: 0, y: 0, width: 1, height: 1)], wholeFrame: true)
  }
}

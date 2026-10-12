import Foundation

/// The masks and dHash baseline one drawn bitmap is processed with.
///
/// Without a mask supplier they are the request's. With one they come from
/// the snapshot taken for that very draw; a supplied capture whose draw has
/// no snapshot is masked whole (fail closed), and the dHash baseline counts
/// only when the drawn structure is the one it was captured with.
struct AppliedMasks {
  let masks: [NormalizedMask]
  let lastDHash: String
  /// The snapshot the frame was masked with; nil without a supplier.
  let snapshot: MaskSnapshot?

  static func of(request: CaptureRequest, bitmap: NativeBitmap, supplied: Bool) -> AppliedMasks {
    guard supplied else {
      return AppliedMasks(masks: request.masks, lastDHash: request.lastDHash, snapshot: nil)
    }
    let snapshot = bitmap.maskSnapshot ?? .failClosed
    let masks = snapshot.wholeFrame ? MaskSnapshot.failClosed.masks : snapshot.masks
    let expected = request.lastStructureSignature
    let sameStructure = expected.isEmpty || expected == snapshot.structureSignature
    return AppliedMasks(masks: masks, lastDHash: sameStructure ? request.lastDHash : "", snapshot: snapshot)
  }
}

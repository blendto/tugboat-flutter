#if canImport(UIKit)
import TugboatCaptureRuntime
import UIKit

/// The mask supplier for one capture. The pixel runtime calls `snapshot`
/// on the main thread in the same turn as each draw, after layout. That one
/// reading of the window gives the draw its masks (fail closed,
/// `WindowMasks`), its structure signature, its boundary (reported as
/// `surface` before anything else of the capture), and, through the
/// runtime's `pixelsPerPoint`, its pixel size; the time the request arrived
/// plays no part.
///
/// Each draw is recorded under the snapshot id the runtime hands back, so
/// the `capture.result` reports the coverage and boundary of the draw the
/// frame actually came from.
final class FrameMasks {
  /// What one draw was masked with, beyond what the runtime reads.
  struct Drawn {
    let geometry: CaptureGeometry
    let coverage: MaskCoverage
  }

  private let compute: (UIWindow) -> MaskResult
  private let screen: () -> String?
  private let onGeometry: (CaptureGeometry) -> Void
  private let drawn = Locked<[Int: Drawn]>([:])

  /// - Parameters:
  ///   - compute: the adapter's mask walk.
  ///   - screen: the current `.tugboatScreen` name, for the signature.
  ///   - onGeometry: the drawn window size, before the draw (`surface`).
  init(
    compute: @escaping (UIWindow) -> MaskResult,
    screen: @escaping () -> String? = { nil },
    onGeometry: @escaping (CaptureGeometry) -> Void = { _ in }
  ) {
    self.compute = compute
    self.screen = screen
    self.onGeometry = onGeometry
  }

  /// The draw a runtime result came from; nil when nothing was supplied
  /// for it (the runtime then masked the frame whole).
  func drawn(_ snapshot: MaskSnapshot?) -> Drawn? {
    guard let id = snapshot?.id else { return nil }
    return drawn.withLock { $0[id] }
  }

  /// Main thread, inside the runtime's draw turn.
  func snapshot(for view: UIView) -> MaskSnapshot {
    guard let window = (view as? UIWindow) ?? view.window,
      let geometry = CaptureGeometry(width: Double(window.bounds.width), height: Double(window.bounds.height))
    else {
      return .failClosed
    }
    onGeometry(geometry)
    let result = compute(window)
    let coverage = result.coverage
    let signature = StructureSignature.of(
      result, width: geometry.width, height: geometry.height,
      controls: StructureProbe.controls(in: window), screen: screen())
    let id = drawn.withLock { (draws: inout [Int: Drawn]) -> Int in
      let id = draws.count + 1
      draws[id] = Drawn(geometry: geometry, coverage: coverage)
      return id
    }
    return MaskSnapshot(
      masks: result.rects.map { NormalizedMask(x: $0.x, y: $0.y, width: $0.width, height: $0.height) },
      wholeFrame: coverage.mode == .wholeFrame,
      structureSignature: signature,
      id: id
    )
  }
}
#endif

#if canImport(UIKit)
import TugboatCaptureRuntime
import UIKit

/// The mask supplier for one capture. The pixel runtime calls `snapshot`
/// on the main thread in the same turn as each draw, so the masks (fail
/// closed, `WindowMasks`), the structure signature, and the boundary all
/// describe the drawn frame; the request's arrival time plays no part.
/// It keeps the boundary of the last draw for the `capture.result`.
final class FrameMasks {
  private let compute: (UIWindow) -> MaskResult
  private let drawnGeometry = Locked<CaptureGeometry?>(nil)

  init(compute: @escaping (UIWindow) -> MaskResult) {
    self.compute = compute
  }

  /// The window size at the last draw; nil until the runtime drew.
  var geometry: CaptureGeometry? {
    drawnGeometry.current
  }

  /// Main thread, inside the runtime's draw turn.
  func snapshot(for view: UIView) -> MaskSnapshot {
    guard let window = (view as? UIWindow) ?? view.window,
      let geometry = CaptureGeometry(
        width: Double(window.bounds.width), height: Double(window.bounds.height),
        screenScale: Double(window.screen.scale))
    else {
      return .failClosed
    }
    drawnGeometry.withLock { $0 = geometry }
    let result = compute(window)
    let coverage = result.coverage.wire
    return MaskSnapshot(
      masks: result.rects.map { NormalizedMask(x: $0.x, y: $0.y, width: $0.width, height: $0.height) },
      wholeFrame: result.fallback != nil,
      structureSignature: StructureSignature.of(result, width: geometry.width, height: geometry.height),
      coverage: MaskCoverageSummary(mode: result.fallback == nil ? .precise : .wholeFrame, reasons: coverage.reasons)
    )
  }
}
#endif

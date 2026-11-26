#if canImport(UIKit)
import TugboatCaptureRuntime
import UIKit

/// The pixel runtime as the capture coordinator uses it; a fake in tests.
protocol WindowCapturer: AnyObject {
  /// Draws `window`, calling `masks` on the main thread immediately before
  /// each draw. `onComplete` runs once, on any thread.
  func capture(
    window: UIWindow,
    request: CaptureRequest,
    masks: @escaping (UIView) -> MaskSnapshot,
    onComplete: @escaping (CaptureResult) -> Void
  )

  /// Later captures complete `disposed`.
  func dispose()
}

/// `TugboatCaptureRuntime` drawing the whole window hierarchy
/// (`drawHierarchy`), so presented sheets and alerts are in the frame.
final class RuntimeWindowCapturer: WindowCapturer {
  private let runtime = CaptureRuntime(coverage: .viewHierarchy)

  func capture(
    window: UIWindow,
    request: CaptureRequest,
    masks: @escaping (UIView) -> MaskSnapshot,
    onComplete: @escaping (CaptureResult) -> Void
  ) {
    runtime.capture(view: window, request: request, maskSupplier: masks, onComplete: onComplete)
  }

  func dispose() {
    runtime.dispose()
  }
}
#endif

#if os(iOS)
import TugboatCaptureRuntime
import UIKit

/// Documentation-only sample. Not built by CI.
enum CaptureSample {
  static func captureOnce(view: UIView, runtime: CaptureRuntime) {
    let request = CaptureRequest(
      requestId: 1,
      pixelWidth: 100,
      pixelHeight: 100,
      force: true,
      lastDHash: "",
      masks: [NormalizedMask(x: 0.0, y: 0.0, width: 0.25, height: 0.25)]
    )
    runtime.capture(view: view, request: request) { result in
      _ = result.status
      _ = result.coverage
      _ = result.incomplete
    }
  }
}
#endif

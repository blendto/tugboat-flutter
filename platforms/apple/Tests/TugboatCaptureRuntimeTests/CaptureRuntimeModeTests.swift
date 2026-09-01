import UIKit
import XCTest

@testable import TugboatCaptureRuntime

final class CaptureRuntimeModeTests: XCTestCase {
  func testEngineSurfaceCaptureReportsEngineSurfaceCoverage() {
    let result = capture(runtime: CaptureRuntime())

    guard case .engineSurface? = result.coverage else {
      return XCTFail("expected engineSurface coverage")
    }
    XCTAssertFalse(result.jpeg.isEmpty)
    XCTAssertFalse(result.incomplete)
  }

  func testHierarchyCompatibilityCaptureReportsViewHierarchyCoverage() {
    let result = capture(runtime: CaptureRuntime(captureMode: .viewHierarchy))

    guard case .viewHierarchy? = result.coverage else {
      return XCTFail("expected viewHierarchy coverage")
    }
    XCTAssertFalse(result.jpeg.isEmpty)
  }

  private func capture(runtime: CaptureRuntime) -> CaptureResult {
    let view = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 60))
    view.backgroundColor = .red
    let completed = expectation(description: "capture completes")
    var captured: CaptureResult?

    runtime.capture(
      view: view,
      request: CaptureRequest(
        requestId: 1,
        pixelWidth: 20,
        pixelHeight: 30,
        force: true
      )
    ) { result in
      captured = result
      completed.fulfill()
    }

    wait(for: [completed], timeout: 2)
    return try! XCTUnwrap(captured)
  }
}

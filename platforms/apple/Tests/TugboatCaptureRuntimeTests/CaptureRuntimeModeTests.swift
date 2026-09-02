import UIKit
import XCTest

@testable import TugboatCaptureRuntime

final class CaptureRuntimeModeTests: XCTestCase {
  func testEngineSurfaceCaptureReportsEngineSurfaceCoverage() throws {
    let result = try capture(runtime: CaptureRuntime())

    XCTAssertEqual(result.coverage, .engineSurface)
    XCTAssertFalse(result.jpeg.isEmpty)
    XCTAssertFalse(result.incomplete)
  }

  func testHierarchyCompatibilityCaptureReportsViewHierarchyCoverage() throws {
    let view = HierarchyDrawingView(
      frame: CGRect(x: 0, y: 0, width: 40, height: 60),
      fillColor: .green
    )

    let result = try capture(runtime: CaptureRuntime(coverage: .viewHierarchy), view: view)

    XCTAssertEqual(result.coverage, .viewHierarchy)
    XCTAssertFalse(result.jpeg.isEmpty)
  }

  func testEngineSurfaceRejectsBlankInsteadOfBroadeningCoverage() throws {
    let view = HierarchyDrawingView(
      frame: CGRect(x: 0, y: 0, width: 40, height: 60),
      fillColor: .green
    )

    let result = try capture(runtime: CaptureRuntime(), view: view)

    XCTAssertEqual(result.status, .pixelCopyFailed)
    XCTAssertNil(result.coverage)
    XCTAssertTrue(result.jpeg.isEmpty)
  }

  func testTransparentCaptureFailsInsteadOfPublishingBlankJpeg() throws {
    let view = HierarchyDrawingView(
      frame: CGRect(x: 0, y: 0, width: 40, height: 60),
      fillColor: .clear
    )

    let result = try capture(
      runtime: CaptureRuntime(coverage: .viewHierarchy),
      view: view
    )

    XCTAssertEqual(result.status, .pixelCopyFailed)
    XCTAssertNil(result.coverage)
    XCTAssertTrue(result.jpeg.isEmpty)
  }

  func testOpaqueWhiteCaptureFailsInsteadOfPublishingBlankJpeg() throws {
    let view = HierarchyDrawingView(
      frame: CGRect(x: 0, y: 0, width: 40, height: 60),
      fillColor: .white
    )

    let result = try capture(
      runtime: CaptureRuntime(coverage: .viewHierarchy),
      view: view
    )

    XCTAssertEqual(result.status, .pixelCopyFailed)
    XCTAssertNil(result.coverage)
    XCTAssertTrue(result.jpeg.isEmpty)
  }

  private func capture(runtime: CaptureRuntime) throws -> CaptureResult {
    let view = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 60))
    view.backgroundColor = .red
    return try capture(runtime: runtime, view: view)
  }

  private func capture(runtime: CaptureRuntime, view: UIView) throws -> CaptureResult {
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
    return try XCTUnwrap(captured)
  }
}

private final class NoRenderLayer: CALayer {
  override func render(in context: CGContext) {}
}

private final class HierarchyDrawingView: UIView {
  private let fillColor: UIColor

  init(frame: CGRect, fillColor: UIColor) {
    self.fillColor = fillColor
    super.init(frame: frame)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override class var layerClass: AnyClass {
    NoRenderLayer.self
  }

  override func drawHierarchy(in rect: CGRect, afterScreenUpdates: Bool) -> Bool {
    fillColor.setFill()
    UIRectFill(rect)
    return true
  }
}

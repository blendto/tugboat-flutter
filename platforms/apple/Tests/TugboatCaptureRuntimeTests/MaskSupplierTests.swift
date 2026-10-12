import UIKit
import XCTest

@testable import TugboatCaptureRuntime

/// `capture(view:request:maskSupplier:onComplete:)`: the supplier runs on the
/// main thread in the draw's turn, its masks are the ones filled, and the
/// dHash skip respects the supplied structure.
final class MaskSupplierTests: XCTestCase {
  private let runtime = CaptureRuntime(coverage: .viewHierarchy)

  func testSupplierRunsOnTheMainThreadAndItsSnapshotIsReturned() throws {
    var onMain: [Bool] = []
    let snapshot = MaskSnapshot(
      masks: [NormalizedMask(x: 0, y: 0, width: 0.5, height: 0.5)],
      structureSignature: "sig-1",
      coverage: MaskCoverageSummary(mode: .precise, reasons: ["webView"])
    )
    let result = try capture(request(id: 1)) { _ in
      onMain.append(Thread.isMainThread)
      return snapshot
    }

    XCTAssertEqual(result.status, .ok)
    XCTAssertEqual(onMain, [true], "one draw, one supplier call, on the main thread")
    XCTAssertEqual(result.maskSnapshot?.structureSignature, "sig-1")
    XCTAssertEqual(result.maskSnapshot?.coverage?.mode, .precise)
    XCTAssertEqual(result.maskSnapshot?.coverage?.reasons, ["webView"])
  }

  func testSuppliedMasksReplaceRequestMasks() throws {
    let unmasked = try capture(request(id: 1, masks: [full])) { _ in MaskSnapshot(masks: []) }
    let masked = try capture(request(id: 2)) { _ in MaskSnapshot(masks: [self.full]) }

    XCTAssertGreaterThan(try centerRed(unmasked), 0xc0, "request masks are ignored")
    XCTAssertEqual(try centerRed(masked), 0x1a, accuracy: 0x10, "supplied masks are filled")
  }

  func testWholeFrameSnapshotMasksEverything() throws {
    let result = try capture(request(id: 1)) { _ in MaskSnapshot(masks: [], wholeFrame: true) }

    XCTAssertEqual(try centerRed(result), 0x1a, accuracy: 0x10)
    XCTAssertEqual(result.maskSnapshot?.wholeFrame, true)
  }

  func testLayoutChangedAfterTheSupplierIsNotDrawnBeforeTheNextTurn() throws {
    let view = solidView(.green)
    let result = try capture(request(id: 1), view: view) { supplied in
      // Queued from inside the supplier: it runs only after the draw.
      DispatchQueue.main.async { supplied.backgroundColor = .white }
      return MaskSnapshot(masks: [])
    }

    XCTAssertEqual(result.status, .ok)
    XCTAssertLessThan(try centerRed(result), 0x40, "the drawn frame is the one the supplier saw")
  }

  func testDHashSkipNeedsTheSameStructure() throws {
    let first = try capture(request(id: 1)) { _ in MaskSnapshot(masks: [], structureSignature: "a") }
    XCTAssertEqual(first.status, .ok)

    let changed = try capture(request(id: 2, lastDHash: first.dHash, lastStructure: "b")) { _ in
      MaskSnapshot(masks: [], structureSignature: "a")
    }
    let same = try capture(request(id: 3, lastDHash: first.dHash, lastStructure: "a")) { _ in
      MaskSnapshot(masks: [], structureSignature: "a")
    }

    XCTAssertEqual(changed.status, .ok, "a different structure is never skipped")
    XCTAssertEqual(same.status, .skippedByDHash)
    XCTAssertEqual(same.maskSnapshot?.structureSignature, "a")
  }

  // MARK: - Helpers

  private let full = NormalizedMask(x: 0, y: 0, width: 1, height: 1)

  private func request(
    id: Int64,
    masks: [NormalizedMask] = [],
    lastDHash: String = "",
    lastStructure: String = ""
  ) -> CaptureRequest {
    CaptureRequest(
      requestId: id, pixelWidth: 20, pixelHeight: 30, force: false, lastDHash: lastDHash,
      masks: masks, lastStructureSignature: lastStructure)
  }

  private func solidView(_ color: UIColor = .red) -> UIView {
    let view = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 60))
    view.backgroundColor = color
    return view
  }

  private func capture(
    _ request: CaptureRequest,
    view: UIView? = nil,
    supplier: @escaping (UIView) -> MaskSnapshot
  ) throws -> CaptureResult {
    let target = view ?? solidView()
    let completed = expectation(description: "capture completes")
    var captured: CaptureResult?
    runtime.capture(view: target, request: request, maskSupplier: supplier) { result in
      captured = result
      completed.fulfill()
    }
    wait(for: [completed], timeout: 3)
    return try XCTUnwrap(captured)
  }

  /// The red channel of the decoded JPEG's center pixel.
  private func centerRed(_ result: CaptureResult) throws -> Double {
    let image = try XCTUnwrap(UIImage(data: result.jpeg)?.cgImage)
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = try XCTUnwrap(
      CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.interpolationQuality = .none
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    context.draw(image, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
    return Double(pixel[0])
  }
}

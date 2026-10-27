import UIKit
import XCTest

@testable import TugboatCaptureRuntime

/// `capture(view:request:maskSupplier:onComplete:)`: the supplier runs on the
/// main thread in each draw's turn after layout, its masks are the ones
/// filled, every draw keeps its own snapshot, the size can follow the
/// draw-time bounds, and the dHash skip needs a known, equal structure.
final class MaskSupplierTests: XCTestCase {
  private let runtime = CaptureRuntime(coverage: .viewHierarchy)

  func testSupplierRunsOnTheMainThreadAndItsSnapshotIsReturned() throws {
    var onMain: [Bool] = []
    let result = try capture(request(id: 1)) { _ in
      onMain.append(Thread.isMainThread)
      return MaskSnapshot(masks: [NormalizedMask(x: 0, y: 0, width: 0.5, height: 0.5)], structureSignature: "sig-1", id: 7)
    }

    XCTAssertEqual(result.status, .ok)
    XCTAssertEqual(onMain, [true], "one draw, one supplier call, on the main thread")
    XCTAssertEqual(result.maskSnapshot?.structureSignature, "sig-1")
    XCTAssertEqual(result.maskSnapshot?.id, 7)
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
    let view = FillView(fill: .green)
    let result = try capture(request(id: 1), view: view) { _ in
      // Queued from inside the supplier: it runs only after the draw.
      DispatchQueue.main.async { view.fill = .white }
      return MaskSnapshot(masks: [])
    }

    XCTAssertEqual(result.status, .ok)
    XCTAssertLessThan(try centerRed(result), 0x40, "the drawn frame is the one the supplier saw")
  }

  func testTheRetriedDrawGetsItsOwnSnapshot() throws {
    // Nothing visible without screen updates, so the runtime draws again
    // with `afterScreenUpdates: true`.
    let view = FillView(fill: .red, blankUntilScreenUpdates: true)
    var ids = 0
    let result = try capture(request(id: 1), view: view) { _ in
      ids += 1
      return MaskSnapshot(masks: [], id: ids)
    }

    XCTAssertEqual(result.status, .ok)
    XCTAssertEqual(ids, 2)
    XCTAssertEqual(result.maskSnapshot?.id, 2, "the frame carries the snapshot of the draw that produced it")
  }

  func testTheIncompleteFallbackKeepsTheFirstDrawsSnapshot() throws {
    // The first draw reports incomplete, the second draws nothing: the
    // runtime falls back to the first bitmap.
    let view = FillView(fill: .red, incompleteThenBlank: true)
    var ids = 0
    let result = try capture(request(id: 1), view: view) { _ in
      ids += 1
      return MaskSnapshot(masks: [], id: ids)
    }

    XCTAssertEqual(result.status, .ok)
    XCTAssertTrue(result.incomplete)
    XCTAssertEqual(ids, 2)
    XCTAssertEqual(result.maskSnapshot?.id, 1)
  }

  func testLayoutIsSettledBeforeEachSupplierCall() throws {
    let view = FillView(fill: .red, blankUntilScreenUpdates: true)
    var layoutsSeen: [Int] = []
    _ = try capture(request(id: 1), view: view) { supplied in
      layoutsSeen.append(view.layouts)
      supplied.setNeedsLayout()
      return MaskSnapshot(masks: [])
    }

    XCTAssertEqual(layoutsSeen.count, 2)
    XCTAssertEqual(layoutsSeen[1], layoutsSeen[0] + 1, "a layout invalidated after one supplier call runs before the next")
  }

  func testThePixelSizeFollowsTheBoundsAtDrawTime() throws {
    let view = FillView(fill: .red)
    let result = try capture(
      CaptureRequest(requestId: 1, pixelWidth: 999, pixelHeight: 999, force: true, pixelsPerPoint: 0.5), view: view
    ) { supplied in
      MaskSnapshot(masks: [], structureSignature: "\(supplied.bounds.width)x\(supplied.bounds.height)")
    }

    XCTAssertEqual(result.status, .ok)
    XCTAssertEqual(result.width, 20)
    XCTAssertEqual(result.height, 30)
    XCTAssertEqual(result.maskSnapshot?.structureSignature, "40.0x60.0")
  }

  func testDHashSkipNeedsAKnownEqualStructure() throws {
    let first = try capture(request(id: 1)) { _ in MaskSnapshot(masks: [], structureSignature: "a") }
    XCTAssertEqual(first.status, .ok)

    let changed = try capture(request(id: 2, lastDHash: first.dHash, lastStructure: "b")) { _ in
      MaskSnapshot(masks: [], structureSignature: "a")
    }
    let unknownBaseline = try capture(request(id: 3, lastDHash: first.dHash, lastStructure: "")) { _ in
      MaskSnapshot(masks: [], structureSignature: "a")
    }
    let unknownDraw = try capture(request(id: 4, lastDHash: first.dHash, lastStructure: "")) { _ in
      MaskSnapshot(masks: [], structureSignature: "")
    }
    let same = try capture(request(id: 5, lastDHash: first.dHash, lastStructure: "a")) { _ in
      MaskSnapshot(masks: [], structureSignature: "a")
    }

    XCTAssertEqual(changed.status, .ok, "a different structure is never skipped")
    XCTAssertEqual(unknownBaseline.status, .ok, "an unknown baseline structure is never skipped")
    XCTAssertEqual(unknownDraw.status, .ok, "an unknown drawn structure is never skipped")
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

  private func capture(
    _ request: CaptureRequest,
    view: UIView? = nil,
    supplier: @escaping (UIView) -> MaskSnapshot
  ) throws -> CaptureResult {
    let target = view ?? FillView(fill: .red)
    let completed = expectation(description: "capture completes")
    var captured: CaptureResult?
    runtime.capture(view: target, request: request, maskSupplier: supplier) { result in
      captured = result
      completed.fulfill()
    }
    // A progress wait, not a speed bound: CI runners stall for seconds.
    wait(for: [completed], timeout: 30)
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

/// Draws one solid color through `drawHierarchy`, without a window, and
/// counts its layouts. It can stay blank until `afterScreenUpdates`, or
/// report its first draw incomplete and then stay blank.
final class FillView: UIView {
  var fill: UIColor
  private(set) var layouts = 0
  private let blankUntilScreenUpdates: Bool
  private let incompleteThenBlank: Bool

  init(fill: UIColor, blankUntilScreenUpdates: Bool = false, incompleteThenBlank: Bool = false) {
    self.fill = fill
    self.blankUntilScreenUpdates = blankUntilScreenUpdates
    self.incompleteThenBlank = incompleteThenBlank
    super.init(frame: CGRect(x: 0, y: 0, width: 40, height: 60))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layouts += 1
  }

  override func drawHierarchy(in rect: CGRect, afterScreenUpdates: Bool) -> Bool {
    if incompleteThenBlank {
      if afterScreenUpdates { return false }
      paint(rect)
      return false
    }
    if blankUntilScreenUpdates && !afterScreenUpdates {
      return true
    }
    paint(rect)
    return true
  }

  private func paint(_ rect: CGRect) {
    fill.setFill()
    UIRectFill(rect)
  }
}

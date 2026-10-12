#if canImport(UIKit)
import TugboatCaptureRuntime
import UIKit
import XCTest

@testable import Tugboat

/// Every `CaptureStatus` maps to one explicit `capture.result`.
final class RuntimeOutcomesTests: XCTestCase {
  private let frames = FrameHandleTable()
  private lazy var outcomes = RuntimeOutcomes(frames: frames, nanoTime: { 5_000_000 })
  private let snapshot = MaskSnapshot(
    masks: [NormalizedMask(x: 0, y: 0, width: 1, height: 0.1)], structureSignature: "drawn",
    coverage: MaskCoverageSummary(mode: .precise, reasons: ["representable"]))

  private func capture(baseline: DHashBaseline? = nil) throws -> InFlightCapture {
    InFlightCapture(
      requestId: "capture-7",
      requestGeometry: try XCTUnwrap(CaptureGeometry(width: 390, height: 844, screenScale: 3)),
      masks: FrameMasks(compute: { _ in .wholeFrame(.noWindow) }),
      offeredBaseline: baseline,
      frameWaitMicros: 12,
      startedNanos: 1_000_000
    )
  }

  private func result(_ status: CaptureStatus, jpeg: Data = Data(), snapshot: MaskSnapshot? = nil) -> CaptureResult {
    CaptureResult(
      requestId: 1, status: status, jpeg: jpeg, width: 293, height: 633, dHash: "0f0f", contentHash: "sha",
      timings: CaptureTimings(surfaceCopyMicros: 100, maskFillMicros: 5, dHashMicros: 6, jpegMicros: 7, sha256Micros: 8, maskComputeMicros: 9),
      maskSnapshot: snapshot)
  }

  func testOkStoresTheJPEGAndReportsTheDrawnMasks() throws {
    let answer = outcomes.answer(try capture(), result(.ok, jpeg: Data([1, 2, 3]), snapshot: snapshot))
    guard case let .captured(id, frame, boundary, timings) = answer else { return XCTFail("\(answer)") }
    XCTAssertEqual(id, "capture-7")
    XCTAssertEqual(frames.get(frame.handle), Data([1, 2, 3]))
    XCTAssertEqual(frame.byteLength, 3)
    XCTAssertEqual(frame.contentHash, "sha")
    XCTAssertEqual(frame.structureSignature, "drawn")
    XCTAssertEqual(frame.maskCoverage, WireMaskCoverage(mode: "precise", reasons: ["representable"]))
    XCTAssertTrue(frame.masked)
    XCTAssertEqual(frame.captureMicros, 4_000)
    XCTAssertEqual(boundary, BoundaryRect(x: 0, y: 0, width: 390, height: 844))
    XCTAssertEqual(timings, CaptureTimingsMicros(frameWaitMicros: 12, readbackMicros: 100, maskMicros: 20, encodeMicros: 15))
  }

  func testOkWithoutASnapshotReportsAWholeFrame() throws {
    guard case let .captured(_, frame, _, _) = outcomes.answer(try capture(), result(.ok, jpeg: Data([1]))) else {
      return XCTFail()
    }
    XCTAssertTrue(frame.masked)
    XCTAssertEqual(frame.maskCoverage.mode, "wholeFrame")
  }

  func testOkWithoutBytesIsAnEncodingFailure() throws {
    XCTAssertEqual(failure(outcomes.answer(try capture(), result(.ok))), .encodingFailed)
  }

  func testDHashSkipReportsTheOfferedBaseline() throws {
    let baseline = DHashBaseline(dHash: "aaaa", structureSignature: "s0")
    let answer = outcomes.answer(try capture(baseline: baseline), result(.skippedByDHash, snapshot: snapshot))
    guard case let .captured(_, frame, _, _) = answer else { return XCTFail("\(answer)") }
    XCTAssertEqual(frame.dHash, "aaaa")
    XCTAssertEqual(frame.structureSignature, "s0")
    XCTAssertEqual(frame.byteLength, 0)
    XCTAssertEqual(frame.contentHash, "")
    XCTAssertEqual(failure(outcomes.answer(try capture(), result(.skippedByDHash))), .readbackFailed)
  }

  func testEveryFailureStatusMapsExplicitly() throws {
    let expected: [(CaptureStatus, CaptureFailure)] = [
      (.unsupportedApi, .boundaryUnavailable),
      (.surfaceUnavailable, .boundaryUnavailable),
      (.unsupportedRenderMode, .boundaryUnavailable),
      (.timeout, .paintTimedOut),
      (.pixelCopyFailed, .readbackFailed),
      (.processingFailed, .encodingFailed),
    ]
    for (status, mapped) in expected {
      XCTAssertEqual(failure(outcomes.answer(try capture(), result(status))), mapped, "\(status)")
    }
    for status in [CaptureStatus.cancelled, .disposed] {
      XCTAssertEqual(outcomes.answer(try capture(), result(status)), .cancelled(requestId: "capture-7"))
    }
  }

  private func failure(_ answer: CaptureAnswer) -> CaptureFailure? {
    if case let .failed(_, failure, _) = answer { return failure }
    return nil
  }
}
#endif

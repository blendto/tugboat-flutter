#if canImport(UIKit)
import TugboatCaptureRuntime
import UIKit
import XCTest

@testable import Tugboat

/// `CaptureCoordinator`: every `capture.request` is answered exactly once,
/// by id, in whatever order the runtime finishes (C16), and masks are taken
/// at draw time.
final class CaptureCoordinatorTests: XCTestCase {
  private let frames = FrameHandleTable()
  private let capturer = FakeCapturer()
  private let answers = Locked<[CaptureAnswer]>([])
  private var surfaces: [CaptureGeometry] = []
  private var window: UIWindow? = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
  private var maskCalls = 0
  private lazy var coordinator = CaptureCoordinator(
    window: { [unowned self] in self.window },
    masks: { [unowned self] _ in
      self.maskCalls += 1
      return MaskResult(rects: [MaskRect(x: 0, y: 0, width: 0.5, height: 0.1)], fallback: nil, stats: MaskStats(webViewBoxes: 1))
    },
    capturer: capturer,
    frames: frames,
    onSurface: { [unowned self] in self.surfaces.append($0) },
    answer: { [answers] answer in answers.withLock { $0.append(answer) } },
    mainThread: { $0() },
    mainAfter: { _, work in DispatchQueue.main.async(execute: work) }
  )

  private func request(_ id: String, force: Bool = true, baseline: DHashBaseline? = nil) -> CaptureRequestEffect {
    CaptureRequestEffect(requestId: id, force: force, requireFreshPaint: force, scale: 1, dHashBaseline: baseline)
  }

  func testOverlappingRequestsAreEachAnsweredByIdInCompletionOrder() throws {
    coordinator.onCaptureRequest(request("capture-1"))
    coordinator.onCaptureRequest(request("capture-2"))
    XCTAssertEqual(capturer.pending.count, 2, "the second request does not wait for the first")
    XCTAssertEqual(coordinator.pendingCount, 2)

    capturer.complete(at: 1, status: .ok)
    capturer.complete(at: 0, status: .ok)

    XCTAssertEqual(answers.current.map { $0.requestId }, ["capture-2", "capture-1"])
    XCTAssertEqual(coordinator.pendingCount, 0)
    for answer in answers.current {
      guard case let .captured(_, frame, boundary, _) = answer else { return XCTFail("\(answer)") }
      XCTAssertNotNil(frames.get(frame.handle))
      XCTAssertEqual(boundary, BoundaryRect(x: 0, y: 0, width: 390, height: 844))
      XCTAssertEqual(frame.maskCoverage, WireMaskCoverage(mode: "precise", reasons: ["webView"]))
      XCTAssertTrue(frame.masked)
    }
  }

  func testALateResultIsAnsweredOnceAndAnUnknownOneIgnored() {
    coordinator.onCaptureRequest(request("capture-1"))
    capturer.complete(at: 0, status: .cancelled)
    capturer.complete(at: 0, status: .ok)
    XCTAssertEqual(answers.current, [.cancelled(requestId: "capture-1")])
  }

  func testMasksAreTakenWhenTheRuntimeDrawsNotWhenTheRequestArrives() throws {
    coordinator.onCaptureRequest(request("capture-1"))
    XCTAssertEqual(maskCalls, 0, "no masks before the draw")
    capturer.complete(at: 0, status: .ok)
    XCTAssertEqual(maskCalls, 1)
    let snapshot = try XCTUnwrap(capturer.suppliedSnapshots.first)
    XCTAssertEqual(snapshot.masks.count, 1)
    XCTAssertFalse(snapshot.wholeFrame)
  }

  func testForcedRequestsAreNeverOfferedTheBaseline() throws {
    let baseline = DHashBaseline(dHash: "ab", structureSignature: "s")
    coordinator.onCaptureRequest(request("capture-1", force: true, baseline: baseline))
    coordinator.onCaptureRequest(request("capture-2", force: false, baseline: baseline))
    let forced = try XCTUnwrap(capturer.pending.first?.request)
    let reusable = try XCTUnwrap(capturer.pending.last?.request)
    XCTAssertTrue(forced.force)
    XCTAssertEqual(forced.lastDHash, "")
    XCTAssertFalse(reusable.force)
    XCTAssertEqual(reusable.lastDHash, "ab")
    XCTAssertEqual(reusable.lastStructureSignature, "s")
  }

  func testTheSurfaceIsReportedBeforeTheCapture() {
    coordinator.onCaptureRequest(request("capture-1"))
    XCTAssertEqual(surfaces.map { $0.boundaryRect }, [BoundaryRect(x: 0, y: 0, width: 390, height: 844)])
    XCTAssertEqual(capturer.pending.first?.request.pixelWidth, 293)
  }

  func testWithoutAWindowItWaitsThenFails() {
    // Each poll advances a fake clock by a second: three polls, then the
    // 3 s window wait is over.
    let clock = Locked<UInt64>(0)
    let waiting = CaptureCoordinator(
      window: { nil }, masks: { _ in .wholeFrame(.noWindow) }, capturer: capturer, frames: frames, onSurface: { _ in },
      answer: { [answers] answer in answers.withLock { $0.append(answer) } },
      mainThread: { $0() },
      mainAfter: { _, work in
        clock.withLock { $0 += 1_000_000_000 }
        work()
      },
      nanoTime: { clock.current })
    waiting.onCaptureRequest(request("capture-1"))
    XCTAssertEqual(answers.current, [.failed(requestId: "capture-1", failure: .boundaryUnavailable, timings: nil)])
    XCTAssertTrue(capturer.pending.isEmpty)
  }

  func testAZeroSizeWindowFailsWithLayoutUnavailable() {
    window = UIWindow(frame: .zero)
    coordinator.onCaptureRequest(request("capture-1"))
    XCTAssertEqual(answers.current, [.failed(requestId: "capture-1", failure: .layoutUnavailable, timings: nil)])
  }
}

/// Holds each capture until the test completes it; completing draws the
/// masks first, as the runtime does.
final class FakeCapturer: WindowCapturer {
  struct Pending {
    let window: UIWindow
    let request: CaptureRequest
    let masks: (UIView) -> MaskSnapshot
    let onComplete: (CaptureResult) -> Void
  }

  private(set) var pending: [Pending] = []
  private(set) var suppliedSnapshots: [MaskSnapshot] = []
  private(set) var disposed = false

  func capture(
    window: UIWindow,
    request: CaptureRequest,
    masks: @escaping (UIView) -> MaskSnapshot,
    onComplete: @escaping (CaptureResult) -> Void
  ) {
    pending.append(Pending(window: window, request: request, masks: masks, onComplete: onComplete))
  }

  func complete(at index: Int, status: CaptureStatus) {
    let entry = pending[index]
    let snapshot = entry.masks(entry.window)
    suppliedSnapshots.append(snapshot)
    let drawn = status == .ok || status == .skippedByDHash
    entry.onComplete(
      CaptureResult(
        requestId: entry.request.requestId, status: status, coverage: drawn ? .viewHierarchy : nil,
        jpeg: status == .ok ? Data([0xFF, 0xD8, 0xFF, 0xD9]) : Data(), width: entry.request.pixelWidth,
        height: entry.request.pixelHeight, dHash: drawn ? "0f0f" : "", contentHash: status == .ok ? "sha" : "",
        maskSnapshot: drawn ? snapshot : nil))
  }

  func dispose() {
    disposed = true
  }
}
#endif

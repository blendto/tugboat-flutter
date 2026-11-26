#if canImport(UIKit)
import TugboatCaptureRuntime
import UIKit
import XCTest

@testable import Tugboat

/// `CaptureCoordinator`: every `capture.request` is answered exactly once,
/// by id, in whatever order the runtime finishes (C16), and masks, boundary,
/// `surface` and size come from one reading at draw time.
final class CaptureCoordinatorTests: XCTestCase {
  private let frames = FrameHandleTable()
  private let capturer = FakeCapturer()
  private let answers = Locked<[CaptureAnswer]>([])
  private var surfaces: [CaptureGeometry] = []
  private let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
  private var maskCalls = 0
  private lazy var coordinator = CaptureCoordinator(
    window: { [unowned self] in self.window },
    masks: { [unowned self] in
      FrameMasks(
        compute: { _ in
          self.maskCalls += 1
          return MaskResult(
            rects: [MaskRect(x: 0, y: 0, width: 0.5, height: 0.1)], fallback: nil, stats: MaskStats(webViewBoxes: 1))
        },
        screen: { "Home" },
        onGeometry: { self.surfaces.append($0) })
    },
    capturer: capturer,
    frames: frames,
    answer: { [answers] answer in answers.withLock { $0.append(answer) } },
    mainThread: { $0() },
    mainAfter: { _, work in DispatchQueue.main.async(execute: work) }
  )

  private func request(_ id: String, force: Bool = true, scale: Double = 1, baseline: DHashBaseline? = nil) -> CaptureRequestEffect {
    CaptureRequestEffect(requestId: id, force: force, requireFreshPaint: force, scale: scale, dHashBaseline: baseline)
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
      XCTAssertEqual(frame.maskCoverage, MaskCoverage(mode: .precise, reasons: [.webView]))
      XCTAssertTrue(frame.masked)
      XCTAssertFalse(frame.structureSignature.isEmpty)
    }
  }

  func testALateResultIsAnsweredOnceAndAnUnknownOneIgnored() {
    coordinator.onCaptureRequest(request("capture-1"))
    capturer.complete(at: 0, status: .cancelled)
    capturer.complete(at: 0, status: .ok)
    XCTAssertEqual(answers.current, [.cancelled(requestId: "capture-1")])
  }

  func testNothingAboutTheWindowIsReadBeforeTheDraw() throws {
    coordinator.onCaptureRequest(request("capture-1"))
    XCTAssertEqual(maskCalls, 0, "no masks before the draw")
    XCTAssertTrue(surfaces.isEmpty, "no surface before the draw")
    capturer.complete(at: 0, status: .ok)
    XCTAssertEqual(maskCalls, 1)
    XCTAssertEqual(surfaces.map { $0.boundaryRect }, [BoundaryRect(x: 0, y: 0, width: 390, height: 844)])
    let snapshot = try XCTUnwrap(capturer.suppliedSnapshots.first)
    XCTAssertEqual(snapshot.masks.count, 1)
    XCTAssertFalse(snapshot.wholeFrame)
  }

  func testGeometryChangedBetweenRequestAndDrawIsTheDrawnOne() throws {
    coordinator.onCaptureRequest(request("capture-1", scale: 0.8))
    window.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
    capturer.complete(at: 0, status: .ok)

    XCTAssertEqual(surfaces.map { $0.boundaryRect }, [BoundaryRect(x: 0, y: 0, width: 844, height: 390)])
    guard case let .captured(_, frame, boundary, _)? = answers.current.first else { return XCTFail() }
    XCTAssertEqual(boundary, BoundaryRect(x: 0, y: 0, width: 844, height: 390))
    XCTAssertEqual(capturer.pending.first?.request.pixelsPerPoint ?? 0, 0.6, accuracy: 1e-9)
    XCTAssertEqual(frame.width, 507, "the size comes from the drawn bounds")
    XCTAssertEqual(frame.height, 234)
  }

  func testTheRetriedDrawsCoverageAndBoundaryAreReported() throws {
    coordinator.onCaptureRequest(request("capture-1"))
    capturer.complete(at: 0, status: .ok, draws: 2, resizeBetweenDraws: CGSize(width: 400, height: 800))
    guard case let .captured(_, _, boundary, _)? = answers.current.first else { return XCTFail() }
    XCTAssertEqual(boundary, BoundaryRect(x: 0, y: 0, width: 400, height: 800))
  }

  func testWithoutADrawTheFrameIsReportedWholeMasked() throws {
    coordinator.onCaptureRequest(request("capture-1"))
    capturer.complete(at: 0, status: .ok, draws: 0)
    guard case let .captured(_, frame, boundary, _)? = answers.current.first else { return XCTFail() }
    XCTAssertNil(boundary)
    XCTAssertEqual(frame.maskCoverage, .failClosed)
    XCTAssertTrue(frame.masked)
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

  func testWithoutAWindowItWaitsThenFails() {
    // Each poll advances a fake clock by a second: three polls, then the
    // 3 s window wait is over.
    let clock = Locked<UInt64>(0)
    let waiting = CaptureCoordinator(
      window: { nil }, masks: { FrameMasks(compute: { _ in .wholeFrame(.noWindow) }) }, capturer: capturer,
      frames: frames,
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
}

/// Holds each capture until the test completes it. Completing acts like the
/// runtime: per draw it calls the supplier, then sizes the frame from the
/// bounds it drew with.
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

  func complete(at index: Int, status: CaptureStatus, draws: Int = 1, resizeBetweenDraws: CGSize? = nil) {
    let entry = pending[index]
    var snapshot: MaskSnapshot?
    for draw in 0..<draws {
      if draw > 0, let size = resizeBetweenDraws {
        entry.window.frame = CGRect(origin: .zero, size: size)
      }
      snapshot = entry.masks(entry.window)
      snapshot.map { suppliedSnapshots.append($0) }
    }
    let drawn = status == .ok || status == .skippedByDHash
    let ratio = entry.request.pixelsPerPoint
    let bounds = entry.window.bounds
    entry.onComplete(
      CaptureResult(
        requestId: entry.request.requestId, status: status, coverage: drawn ? .viewHierarchy : nil,
        jpeg: status == .ok ? Data([0xFF, 0xD8, 0xFF, 0xD9]) : Data(),
        width: Int((Double(bounds.width) * ratio - 1e-6).rounded(.up)),
        height: Int((Double(bounds.height) * ratio - 1e-6).rounded(.up)),
        dHash: drawn ? "0f0f" : "", contentHash: status == .ok ? "sha" : "",
        maskSnapshot: drawn ? snapshot : nil))
  }

  func dispose() {
    disposed = true
  }
}
#endif

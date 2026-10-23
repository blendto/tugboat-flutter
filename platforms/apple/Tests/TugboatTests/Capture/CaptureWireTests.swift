import Foundation
import XCTest

@testable import Tugboat

/// The `capture.result` and `surface` inputs, the capture pixel ratio, the
/// structure signature, and the mask coverage vocabulary.
final class CaptureWireTests: XCTestCase {
  private let frame = CapturedFrame(
    handle: "frame-1", width: 293, height: 633, contentHash: "abc", masked: true, byteLength: 1200,
    captureMicros: 4500, dHash: "0f0f", structureSignature: "s1",
    maskCoverage: MaskCoverage(mode: .precise, reasons: [.webView, .renderer]))

  func testCapturedAnswerPinsTheNativeBackendAndTheMaskCoverage() {
    let answer = CaptureAnswer.captured(
      requestId: "capture-3", frame: frame, boundaryRect: BoundaryRect(x: 0, y: 0, width: 390, height: 844),
      timings: CaptureTimingsMicros(frameWaitMicros: 10, readbackMicros: 20, maskMicros: 30, encodeMicros: 40))
    XCTAssertEqual(
      CaptureResultJSON.encode(answer),
      "{\"requestId\":\"capture-3\",\"outcome\":\"captured\",\"frame\":{\"handle\":\"frame-1\",\"width\":293,"
        + "\"height\":633,\"contentHash\":\"abc\",\"masked\":true,\"byteLength\":1200,\"captureMicros\":4500,"
        + "\"requestedBackend\":\"nativeCpuExperimental\",\"resolvedBackend\":\"nativeCpuExperimental\","
        + "\"dHash\":\"0f0f\",\"structureSignature\":\"s1\","
        + "\"maskCoverage\":{\"mode\":\"precise\",\"reasons\":[\"webView\",\"renderer\"]}},"
        + "\"boundaryRect\":{\"x\":0,\"y\":0,\"width\":390,\"height\":844},\"timings\":{\"frameWaitMicros\":10,"
        + "\"readbackMicros\":20,\"maskMicros\":30,\"encodeMicros\":40}}")
    XCTAssertEqual(answer.frameHandles, ["frame-1"])
  }

  func testAFrameWithoutARecordedDrawHasNoBoundary() {
    let answer = CaptureAnswer.captured(requestId: "c", frame: frame, boundaryRect: nil, timings: CaptureTimingsMicros())
    XCTAssertNil(jsonObject(CaptureResultJSON.encode(answer))["boundaryRect"])
  }

  func testFailedAndCancelledAnswers() {
    XCTAssertEqual(
      CaptureResultJSON.encode(.failed(requestId: "capture-1", failure: .paintTimedOut, timings: nil)),
      "{\"requestId\":\"capture-1\",\"outcome\":\"failed\",\"failure\":\"paintTimedOut\"}")
    XCTAssertEqual(
      CaptureResultJSON.encode(.cancelled(requestId: "capture-2")),
      "{\"requestId\":\"capture-2\",\"outcome\":\"cancelled\"}")
    XCTAssertEqual(CaptureAnswer.cancelled(requestId: "c").frameHandles, [])
  }

  func testTimingsAreClampedToTheEngineBounds() {
    let answer = CaptureAnswer.failed(
      requestId: "c", failure: .readbackFailed,
      timings: CaptureTimingsMicros(frameWaitMicros: -5, readbackMicros: .max, maskMicros: 0, encodeMicros: 1))
    let timings = jsonObject(CaptureResultJSON.encode(answer))["timings"] as? [String: Any]
    XCTAssertEqual(timings?["frameWaitMicros"] as? Int64, 0)
    XCTAssertEqual(timings?["readbackMicros"] as? Int64, 86_400_000_000)
  }

  func testSurfaceGenerationAdvancesOnlyOnChange() {
    var posted: [String] = []
    let reporter = SurfaceReporter { posted.append($0) }
    let portrait = BoundaryRect(x: 0, y: 0, width: 390, height: 844)
    let landscape = BoundaryRect(x: 0, y: 0, width: 844, height: 390)
    reporter.observe(portrait)
    reporter.observe(portrait)
    reporter.observe(landscape)
    reporter.observe(portrait)
    XCTAssertEqual(
      posted,
      [
        "{\"boundaryRect\":{\"x\":0,\"y\":0,\"width\":390,\"height\":844},\"generation\":0}",
        "{\"boundaryRect\":{\"x\":0,\"y\":0,\"width\":844,\"height\":390},\"generation\":1}",
        "{\"boundaryRect\":{\"x\":0,\"y\":0,\"width\":390,\"height\":844},\"generation\":2}",
      ])
  }

  func testPixelRatioFollowsFlutterAndTheEngineScale() {
    XCTAssertEqual(CaptureGeometry.pixelsPerPoint(scale: 1), 0.75)
    XCTAssertEqual(CaptureGeometry.pixelsPerPoint(scale: 0.8), 0.6, accuracy: 1e-9)
    XCTAssertEqual(CaptureGeometry.pixelsPerPoint(scale: 0), 0.075, accuracy: 1e-9, "bounded below")
    XCTAssertEqual(CaptureGeometry.pixelsPerPoint(scale: 5), 0.75, "bounded above")
    XCTAssertEqual(CaptureGeometry.pixelsPerPoint(scale: .nan), 0.75)
    XCTAssertNil(CaptureGeometry(width: 0, height: 10))
    XCTAssertNil(CaptureGeometry(width: .infinity, height: 10))
    XCTAssertEqual(CaptureGeometry(width: 390, height: 844)?.boundaryRect, BoundaryRect(x: 0, y: 0, width: 390, height: 844))
  }

  func testStructureSignatureFollowsGeometryControlsAndScreen() {
    let rect = MaskRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05)
    let base = MaskResult(rects: [rect], fallback: nil, stats: MaskStats())
    let same = MaskResult(rects: [rect], fallback: nil, stats: MaskStats(hostingViews: 3))
    let moved = MaskResult(rects: [MaskRect(x: 0.1, y: 0.25, width: 0.3, height: 0.05)], fallback: nil, stats: MaskStats())
    let signature = StructureSignature.of(base, width: 390, height: 844, controls: [0x1_12], screen: "Home")
    XCTAssertEqual(signature, StructureSignature.of(same, width: 390, height: 844, controls: [0x1_12], screen: "Home"))
    XCTAssertNotEqual(signature, StructureSignature.of(moved, width: 390, height: 844, controls: [0x1_12], screen: "Home"))
    XCTAssertNotEqual(signature, StructureSignature.of(base, width: 844, height: 390, controls: [0x1_12], screen: "Home"))
    XCTAssertNotEqual(
      signature, StructureSignature.of(base, width: 390, height: 844, controls: [0x1_32], screen: "Home"),
      "a switch turned on changes it")
    XCTAssertNotEqual(
      signature, StructureSignature.of(base, width: 390, height: 844, controls: [0x1_12], screen: "Details"),
      "another screen changes it")
    XCTAssertNotEqual(
      StructureSignature.of(.wholeFrame(.animating), width: 1, height: 1),
      StructureSignature.of(MaskResult(rects: [.fullFrame], fallback: nil, stats: MaskStats()), width: 1, height: 1))
    XCTAssertFalse(signature.isEmpty)
  }

  func testEveryCoverageReasonIsInTheEngineVocabulary() {
    // core/session-engine/README.md, `capture.result` `maskCoverage.reasons`.
    let engineReasons: Set<String> = [
      "composeDefault", "composeVersionUnverified", "composeOwnerUnavailable", "interop", "regionUnreadable",
      "treeUnreadable", "animating", "unverifiedLayerAllowlist", "walkExhausted", "noWindowSize", "noDecor",
      "representable", "webView", "renderer", "surfaceLayer", "unclassifiedLayer", "secureText",
      "overlayWindow",
    ]
    for reason in MaskCoverage.Reason.allCases {
      XCTAssertTrue(engineReasons.contains(reason.rawValue), "\(reason)")
    }
    XCTAssertEqual(MaskResult.wholeFrame(.unverifiedLayerAllowlist(iOSMajor: 17)).coverage.mode, .wholeFrame)
    XCTAssertEqual(MaskCoverage.failClosed, MaskCoverage(mode: .wholeFrame, reasons: [.walkExhausted]))
  }
}

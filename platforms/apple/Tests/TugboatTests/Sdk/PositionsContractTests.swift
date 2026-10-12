import Foundation
import XCTest

@testable import Tugboat

/// The real engine, fed what the SDK sends (`engine.configure`,
/// `session.start`, `surface`, `capture.result` with the drawn
/// `boundaryRect`, pointer facts in window points): an interaction after
/// the first frame has a normalised `position`.
final class PositionsContractTests: XCTestCase {
  private let app = TugboatConfig.App(
    name: "Positions", version: "1.0", buildNumber: "1", appId: "com.tugboat.positions", installationId: "i-1")
  private let device = DeviceSnapshot(
    id: "vendor-1", model: "iPhone", osVersion: "26.0", screenWidth: 402, screenHeight: 874, scale: 3,
    locale: LocaleSnapshot(language: "en", country: "US", script: nil), timezone: "GMT")
  private let boundary = BoundaryRect(x: 0, y: 0, width: 402, height: 874)
  private var bridge: EngineBridge!
  private var monoUs: Int64 = 5_000_000
  private var frameNo = 0

  override func setUpWithError() throws {
    bridge = try XCTUnwrap(EngineBridge.open())
  }

  override func tearDown() {
    bridge.close()
    super.tearDown()
  }

  func testASwipeAfterTheFirstFrameHasPositions() throws {
    let config = TugboatConfig(
      collector: .init(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:9")), apiKey: "k"), app: app)
    let metadata = HostMetadata(app: app, device: device)
    _ = submit(SessionMessages.engineConfigure, EngineConfiguration.build(config: config, host: metadata, gesture: .uiKitDefault).json, timed: false)
    var effects = submit(
      SessionMessages.sessionStart, SessionMessages.sessionStartInput(viewport: (402, 874), host: metadata, sessionEpoch: 0)
    ).effects
    var surfaceInput = ""
    SurfaceReporter { surfaceInput = $0 }.observe(boundary)
    effects += submit(SurfaceReporter.factType, surfaceInput).effects
    try answerCaptures(in: effects)

    _ = submit(FactTypes.pointer, pointer("down", x: 100, y: 200))
    _ = submit(FactTypes.pointer, pointer("move", x: 100, y: 400))
    var records = submit(FactTypes.pointer, pointer("up", x: 100, y: 600))
    records = try answerCaptures(in: records.effects)

    let interaction = try XCTUnwrap(
      records.events.first { $0["type"] as? String == "interaction" }, "the swipe publishes after its capture")
    let text = String(data: try JSONSerialization.data(withJSONObject: interaction), encoding: .utf8) ?? ""
    XCTAssertTrue(text.contains("\"position\""), text)
    XCTAssertTrue(text.contains("\"xNorm\""), text)
  }

  // MARK: - Driving the engine

  private struct Output {
    var events: [[String: Any]] = []
    var effects: [[String: Any]] = []
  }

  private func pointer(_ phase: String, x: Double, y: Double) -> String {
    "{\"pointerId\":1,\"phase\":\"\(phase)\",\"x\":\(x),\"y\":\(y),\"device\":\"touch\"}"
  }

  /// Answers every `capture.request` in `effects` with a captured frame
  /// carrying the drawn boundary, as `RuntimeOutcomes` does; returns the
  /// records those answers produced.
  @discardableResult
  private func answerCaptures(in effects: [[String: Any]]) throws -> Output {
    var out = Output()
    for effect in effects where effect["type"] as? String == "capture.request" {
      let requestId = try XCTUnwrap(effect["requestId"] as? String)
      frameNo += 1
      let frame = CapturedFrame(
        handle: "frame-\(frameNo)", width: 302, height: 656, contentHash: "sha-\(frameNo)", masked: true,
        byteLength: 4, captureMicros: 1000, dHash: "0f0f0f0f0f0f0f0f", structureSignature: "s\(frameNo)",
        maskCoverage: MaskCoverage(mode: .precise, reasons: []))
      let answer = CaptureAnswer.captured(
        requestId: requestId, frame: frame, boundaryRect: boundary, timings: CaptureTimingsMicros())
      let answered = submit(HostMessages.captureResult, CaptureResultJSON.encode(answer))
      out.events += answered.events
      out.effects += answered.effects
    }
    return out
  }

  private func submit(_ type: String, _ input: String, timed: Bool = true) -> Output {
    monoUs += 20_000
    let at = timed ? HostTime(monoUs: monoUs, wallUs: 1_791_712_345_678_901 + monoUs) : nil
    let response = bridge.submit(Data(EngineMessage(type: type, inputJSON: input, at: at).json.utf8))
    XCTAssertEqual(response.statusName, "ok", "\(type): \(response.text)")
    let document = jsonObject(response.text)
    var out = Output()
    out.effects = document["effects"] as? [[String: Any]] ?? []
    for record in document["records"] as? [[String: Any]] ?? [] {
      if let event = record["event"] as? [String: Any] {
        out.events.append(event)
      }
    }
    return out
  }
}

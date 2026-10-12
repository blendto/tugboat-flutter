import Foundation
import XCTest

@testable import Tugboat

/// The real engine, fed what the SDK sends (`engine.configure`,
/// `session.start`, `surface`, `navigation` from `.tugboatScreen`,
/// `capture.result` with the drawn `boundaryRect`, pointer facts in window
/// points), with its timers fired on a simulated clock: interactions after
/// the first frame have a normalised `position`.
final class PositionsContractTests: XCTestCase {
  private let app = TugboatConfig.App(
    name: "Positions", version: "1.0", buildNumber: "1", appId: "com.tugboat.positions", installationId: "i-1")
  private let device = DeviceSnapshot(
    id: "vendor-1", model: "iPhone", osVersion: "26.0", screenWidth: 402, screenHeight: 874, scale: 3,
    locale: LocaleSnapshot(language: "en", country: "US", script: nil), timezone: "GMT")
  private let boundary = BoundaryRect(x: 0, y: 0, width: 402, height: 874)
  private var engine: SimulatedEngine!

  override func setUpWithError() throws {
    engine = SimulatedEngine(bridge: try XCTUnwrap(EngineBridge.open()), boundary: boundary)
    let config = TugboatConfig(
      collector: .init(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:9")), apiKey: "k"), app: app)
    let metadata = HostMetadata(app: app, device: device)
    engine.send(
      SessionMessages.engineConfigure, EngineConfiguration.build(config: config, host: metadata, gesture: .uiKitDefault).json,
      timed: false)
    engine.send(
      SessionMessages.sessionStart, SessionMessages.sessionStartInput(viewport: (402, 874), host: metadata, sessionEpoch: 0))
    var surfaceInput = ""
    SurfaceReporter { surfaceInput = $0 }.observe(boundary)
    engine.send(SurfaceReporter.factType, surfaceInput)
    let home = NavigationChange(
      kind: .push, navigatorId: ScreenTracker.navigatorId,
      route: RouteEntry(instanceId: "swiftui-screen-1", name: "Home", type: ScreenTracker.routeType), departing: nil)
    engine.send(FactTypes.navigation, home.fact(at: engine.now).input.json)
    engine.run(forMs: 3000)
  }

  override func tearDown() {
    engine.close()
    super.tearDown()
  }

  func testATapAfterTheFirstFrameHasAPosition() throws {
    engine.send(FactTypes.pointer, pointer("down", x: 100, y: 200))
    engine.run(forMs: 40)
    engine.send(FactTypes.pointer, pointer("up", x: 100, y: 200))
    engine.run(forMs: 5000)

    let tap = try XCTUnwrap(engine.interactions.first, "the tap publishes; events: \(engine.eventTypes)")
    let text = String(data: try JSONSerialization.data(withJSONObject: tap), encoding: .utf8) ?? ""
    XCTAssertTrue(text.contains("\"position\""), text)
  }

  func testASwipeAfterTheFirstFrameHasPositions() throws {
    engine.send(FactTypes.pointer, pointer("down", x: 100, y: 200))
    engine.run(forMs: 20)
    engine.send(FactTypes.pointer, pointer("move", x: 100, y: 400))
    engine.run(forMs: 20)
    engine.send(FactTypes.pointer, pointer("up", x: 100, y: 600))
    engine.run(forMs: 3000)

    let swipe = try XCTUnwrap(engine.interactions.first, "the swipe publishes; events: \(engine.eventTypes)")
    let text = String(data: try JSONSerialization.data(withJSONObject: swipe), encoding: .utf8) ?? ""
    XCTAssertTrue(text.contains("\"position\""), text)
    XCTAssertTrue(text.contains("\"endPosition\""), text)
  }

  private func pointer(_ phase: String, x: Double, y: Double) -> String {
    "{\"pointerId\":1,\"phase\":\"\(phase)\",\"x\":\(x),\"y\":\(y),\"device\":\"touch\"}"
  }
}

/// Drives one engine handle synchronously on a simulated monotonic clock:
/// fires its timers in order and answers every `capture.request` at once
/// with a captured frame carrying the drawn boundary, as `RuntimeOutcomes`
/// does.
final class SimulatedEngine {
  private let bridge: EngineBridge
  private let boundary: BoundaryRect
  private var monoUs: Int64 = 5_000_000
  private var timers: [String: Int64] = [:]
  private var frameNo = 0
  private(set) var events: [[String: Any]] = []

  init(bridge: EngineBridge, boundary: BoundaryRect) {
    self.bridge = bridge
    self.boundary = boundary
  }

  var now: HostTime {
    HostTime(monoUs: monoUs, wallUs: 1_791_712_345_678_901 + monoUs)
  }

  var interactions: [[String: Any]] {
    events.filter { $0["type"] as? String == "interaction" }
  }

  var eventTypes: [String] {
    events.compactMap { $0["type"] as? String }
  }

  func close() {
    bridge.close()
  }

  func send(_ type: String, _ input: String, timed: Bool = true) {
    let response = bridge.submit(Data(EngineMessage(type: type, inputJSON: input, at: timed ? now : nil).json.utf8))
    XCTAssertEqual(response.statusName, "ok", "\(type): \(response.text)")
    let document = jsonObject(response.text)
    for record in document["records"] as? [[String: Any]] ?? [] {
      if let event = record["event"] as? [String: Any] {
        events.append(event)
      }
    }
    var captures: [String] = []
    for effect in document["effects"] as? [[String: Any]] ?? [] {
      switch effect["type"] as? String {
      case "timer.schedule":
        if let id = effect["timerId"] as? String, let at = (effect["atMonoUs"] as? NSNumber)?.int64Value {
          timers[id] = at
        }
      case "timer.cancel":
        if let id = effect["timerId"] as? String { timers[id] = nil }
      case "capture.request":
        if let id = effect["requestId"] as? String { captures.append(id) }
      default:
        break
      }
    }
    for requestId in captures {
      answer(requestId)
    }
  }

  /// Advances the clock by `ms`, firing every timer due on the way.
  func run(forMs ms: Int64) {
    let until = monoUs + ms * 1000
    while let next = timers.min(by: { $0.value < $1.value }), next.value <= until {
      timers[next.key] = nil
      monoUs = max(monoUs, next.value)
      send(HostMessages.timerFired, HostMessages.timerFiredInput(timerId: next.key))
    }
    monoUs = until
  }

  private func answer(_ requestId: String) {
    monoUs += 1000
    frameNo += 1
    let frame = CapturedFrame(
      handle: "frame-\(frameNo)", width: 302, height: 656, contentHash: "sha-\(frameNo)", masked: true,
      byteLength: 4, captureMicros: 1000, dHash: String(format: "%016x", frameNo), structureSignature: "s\(frameNo)",
      maskCoverage: MaskCoverage(mode: .precise, reasons: []))
    let answer = CaptureAnswer.captured(
      requestId: requestId, frame: frame, boundaryRect: boundary, timings: CaptureTimingsMicros())
    send(HostMessages.captureResult, CaptureResultJSON.encode(answer))
  }
}

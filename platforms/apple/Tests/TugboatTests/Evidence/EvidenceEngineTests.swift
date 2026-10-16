import Foundation
import TugboatSessionEngine
import XCTest

@testable import Tugboat

/// The public evidence API against the real session engine: the event
/// `data` it records is what Dart records for the same input.
final class EvidenceEngineTests: XCTestCase {
  private var engine: EngineEvidenceSink!
  private var channel: EvidenceChannel!
  private let clock = FakeClock(monoUs: 10_000_000, wallUs: 1_791_712_345_678_901)

  override func setUpWithError() throws {
    try super.setUpWithError()
    let bridge = try XCTUnwrap(EngineBridge.open(), "the engine must open")
    // Until engine/native-evidence is merged into this branch's base.
    let probe = bridge.submit(Data(EngineMessage(type: EvidenceMessages.networkCall, inputJSON: "{}", at: clock.now()).json.utf8))
    if probe.status == TB_SESSION_UNSUPPORTED_MESSAGE {
      bridge.close()
      throw XCTSkip("this engine has no evidence.* messages yet")
    }
    engine = EngineEvidenceSink(bridge: bridge)
    try engine.startSession(at: clock.now())
    channel = EvidenceChannel(clock: clock, schedule: { $0() })
    channel.open(engine)
  }

  override func tearDown() {
    engine?.close()
    super.tearDown()
  }

  func testACodedEventUnderAnAllowList() throws {
    let hook = TugboatEventHook(source: " analytics ", policy: .allowList(["method", "tries"]), channel: channel)
    hook.record(" USER_LOGIN ", parameters: ["method": "email", "email": "u@example.com", "tries": 2, "": "x"])

    let event = try XCTUnwrap(engine.events.last)
    XCTAssertEqual(event["type"] as? String, "external_event")
    XCTAssertEqual(event["stream"] as? String, "evidence")
    XCTAssertEqual(
      event["data"] as? NSDictionary,
      [
        "source": "analytics", "name": "USER_LOGIN", "parameterKeys": ["email", "method", "tries"],
        "parameters": ["method": "email", "tries": 2],
        "capture": ["values": "allow_list", "truncated": true, "droppedCount": 2],
      ])
  }

  func testATransformAndBoundedValues() throws {
    let hook = TugboatEventHook(
      source: nil,
      policy: .transform { key, value in
        if key == "secret" { return TugboatParameterPolicy.drop }
        if key == "fail" { throw TransformFailure() }
        return value
      }, channel: channel)
    hook.record(
      "SEARCH",
      parameters: [
        "secret": "x", "fail": 1, "ratio": 0.5, "whole": 2.0, "nan": Double.nan,
        "deep": [[[[1]]]], "tags": ["a", "b"], "date": Date(),
      ])

    let data = try XCTUnwrap(engine.events.last?["data"] as? [String: Any])
    XCTAssertEqual(data["parameterKeys"] as? [String], ["date", "deep", "fail", "nan", "ratio", "secret", "tags", "whole"])
    XCTAssertEqual(
      data["parameters"] as? NSDictionary, ["deep": [[[[]]]], "ratio": 0.5, "tags": ["a", "b"], "whole": 2.0])
    XCTAssertEqual(data["capture"] as? NSDictionary, ["values": "transform", "truncated": true, "droppedCount": 5])
  }

  func testANetworkCallWithAnErrorBodyKeepsItsStart() throws {
    let call = TugboatNetworkCall.begin(method: "get", route: "/orders/123", channel: channel)
    clock.set(monoUs: 10_250_000)
    call.complete(statusCode: 422, attemptCount: 2, errorResponseBody: ["error": "invalid_order", "fields": ["qty"]])
    call.complete(statusCode: 200)

    XCTAssertEqual(engine.events.filter { $0["type"] as? String == "network_call" }.count, 1)
    let event = try XCTUnwrap(engine.events.last)
    XCTAssertEqual(event["type"] as? String, "network_call")
    XCTAssertEqual(
      event["data"] as? NSDictionary,
      [
        "method": "GET", "route": "/orders/123", "statusCode": 422, "outcome": "response", "durationMs": 250,
        "attemptCount": 2, "errorResponseBody": ["error": "invalid_order", "fields": ["qty"]],
        "errorResponseBodyCapture": ["format": "json", "representation": "native", "truncated": false],
      ])
  }

  func testAFailedCallAndAnInvalidRouteRecordNothingBadly() throws {
    TugboatNetworkCall.begin(method: "POST", route: "/upload", channel: channel)
      .fail(.networkError, errorResponseBody: "ignored without a status")
    TugboatNetworkCall.begin(method: "GET", route: "/search?q=x", channel: channel).complete(statusCode: 200)
    TugboatNetworkCall.begin(method: "GET", route: "/text", channel: channel)
      .complete(statusCode: 500, errorResponseBody: "upstream down")

    let calls = engine.events.compactMap { $0["data"] as? [String: Any] }
    XCTAssertEqual(calls.map { $0["route"] as? String }, ["/upload", "/text"], "the engine drops a route with a query")
    XCTAssertEqual(calls[0]["outcome"] as? String, "network_error")
    XCTAssertNil(calls[0]["errorResponseBody"])
    XCTAssertEqual(calls[1]["errorResponseBody"] as? String, "upstream down")
    XCTAssertEqual(
      calls[1]["errorResponseBodyCapture"] as? NSDictionary,
      ["format": "text", "representation": "native", "truncated": false])
  }
}

/// Submits evidence straight to a real engine and keeps the events it records.
final class EngineEvidenceSink: EvidenceSink {
  private let bridge: EngineBridge
  private(set) var events: [[String: Any]] = []

  init(bridge: EngineBridge) {
    self.bridge = bridge
  }

  var isRunning: Bool { true }

  func startSession(at: HostTime) throws {
    let app = TugboatConfig.App(
      name: "Evidence", version: "1.0.0", buildNumber: "1", appId: "com.tugboat.evidence", installationId: "install-1")
    let device = DeviceSnapshot(
      id: "vendor-1", model: "iPhone", osVersion: "26.0", screenWidth: 402, screenHeight: 874, scale: 3,
      locale: LocaleSnapshot(language: "en", country: "US", script: nil), timezone: "GMT")
    let config = TugboatConfig(
      collector: .init(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:9")), apiKey: "key"), app: app)
    let metadata = HostMetadata(app: app, device: device)
    try submit(
      EngineMessage(
        type: SessionMessages.engineConfigure,
        inputJSON: EngineConfiguration.build(config: config, host: metadata, gesture: .uiKitDefault).json, at: nil))
    try submit(
      EngineMessage(
        type: SessionMessages.sessionStart,
        inputJSON: SessionMessages.sessionStartInput(viewport: (402, 874), host: metadata, sessionEpoch: 0), at: at))
    events.removeAll()
  }

  func postEvidence(type: String, inputJSON: String, at: HostTime) {
    XCTAssertNoThrow(try submit(EngineMessage(type: type, inputJSON: inputJSON, at: at)))
  }

  func close() {
    bridge.close()
  }

  private func submit(_ message: EngineMessage) throws {
    let response = bridge.submit(Data(message.json.utf8))
    guard response.status == TB_SESSION_OK else {
      throw EngineRefused(text: response.text)
    }
    let records = jsonObject(response.text)["records"] as? [[String: Any]] ?? []
    events += records.filter { $0["kind"] as? String == "event" }.compactMap { $0["event"] as? [String: Any] ?? $0 }
  }

  struct EngineRefused: Error {
    let text: String
  }
}

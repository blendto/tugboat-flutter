import Foundation
import XCTest

@testable import Tugboat

/// Contract test (native SDK note section 8): the real engine, driven
/// through the host with the SDK's own `engine.configure`, `session.start`,
/// and `capture.result` builders, must produce collector bodies the
/// collector accepts. Pins the `session_start` body (every required field)
/// and `frameMetadata[].requestedBackend` / `resolvedBackend` =
/// `iosViewHierarchy`. Only the HTTP transport is fake: it records each
/// `http.send` and answers 202.
final class CollectorContractTests: XCTestCase {
  private let app = TugboatConfig.App(
    name: "Contract", version: "3.1.4", buildNumber: "314", appId: "com.tugboat.contract", installationId: "install-1")
  private let device = DeviceSnapshot(
    id: "vendor-1", model: "iPhone", osVersion: "26.0", screenWidth: 402, screenHeight: 874, scale: 3,
    locale: LocaleSnapshot(language: "en", country: "US", script: nil), timezone: "GMT+1")
  private let frames = FrameHandleTable()
  private let http = AcceptingSender()
  private var captures: AnsweringCaptures!
  private var host: EngineHost?

  override func tearDown() {
    host?.close()
    super.tearDown()
  }

  func testSessionStartAndFrameUploadsMatchTheCollectorContract() throws {
    let config = TugboatConfig(
      collector: .init(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:9")), apiKey: "key"), app: app,
      captureFocusChanges: true)
    let metadata = HostMetadata(app: app, device: device)
    XCTAssertEqual(metadata.missingFields, [])
    let transport = try XCTUnwrap(EngineBridge.open(), "the engine must open")
    captures = AnsweringCaptures(frames: frames)
    let host = EngineHost.start(transport: transport, frames: frames, http: http, captures: captures)
    self.host = host
    captures.host = host

    host.postUntimed(
      type: SessionMessages.engineConfigure,
      inputJSON: EngineConfiguration.build(config: config, host: metadata, gesture: .uiKitDefault).json)
    host.post(
      type: SessionMessages.sessionStart,
      inputJSON: SessionMessages.sessionStartInput(viewport: (402, 874), host: metadata, sessionEpoch: 0),
      at: SystemHostClock().now())

    let start = jsonObject(try awaitRequest { $0.lane == "lifecycle" }.jsonText)
    XCTAssertEqual(start["eventType"] as? String, "session_start")
    for key in ["sessionId", "atMs", "triggeredAt"] {
      XCTAssertNotNil(start[key], key)
    }
    XCTAssertTrue(start["userId"] is NSNull)
    XCTAssertEqual(
      start["appInfo"] as? NSDictionary,
      ["version": "3.1.4", "buildNumber": "314", "appId": "com.tugboat.contract", "packageName": "com.tugboat.contract"])
    XCTAssertEqual(
      start["device"] as? NSDictionary,
      [
        "id": "vendor-1", "platform": "ios", "model": "iPhone", "osVersion": "26.0",
        "screenSize": ["width": 402, "height": 874], "screenDensity": 3, "screenDpi": 480, "screenPixelDensity": 3,
      ])
    XCTAssertEqual(start["ipInfo"] as? NSDictionary, ["ip": "127.0.0.1"])
    XCTAssertEqual(
      start["locale"] as? NSDictionary,
      ["timezone": "GMT+1", "language": "en", "country": "US", "tag": "en-US"])

    let upload = try awaitRequest { $0.lane == "frames" }
    guard case let .multipart(fields, parts) = upload.body else { return XCTFail("frames are multipart") }
    XCTAssertFalse(parts.isEmpty)
    let metadataField = try XCTUnwrap(fields.first { $0.name == "frameMetadata" }?.value)
    let entries = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(metadataField.utf8)) as? [[String: Any]])
    XCTAssertFalse(entries.isEmpty)
    for entry in entries {
      XCTAssertEqual(entry["requestedBackend"] as? String, "iosViewHierarchy")
      XCTAssertEqual(entry["resolvedBackend"] as? String, "iosViewHierarchy")
    }

    host.post(type: SessionMessages.sessionEnd, inputJSON: SessionMessages.sessionEndInput(), at: SystemHostClock().now())
    let end = try awaitRequest { $0.lane == "lifecycle" && $0.jsonText.contains("session_end") }
    XCTAssertTrue(SessionEndWatcher.isSessionEnd(end))
    XCTAssertGreaterThan(captures.answered, 0)
  }

  private func awaitRequest(timeout: TimeInterval = 20, _ match: (HTTPRequest) -> Bool) throws -> HTTPRequest {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let found = http.requests.first(where: match) {
        return found
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    throw NoRequest(seen: http.requests.map { $0.lane + " " + $0.path })
  }

  private struct NoRequest: Error {
    let seen: [String]
  }
}

extension HTTPRequest {
  var jsonText: String {
    if case let .json(text) = body { return text }
    return ""
  }
}

/// Records each request and accepts it, with a collector session id for
/// lifecycle posts.
final class AcceptingSender: HTTPSender {
  private let recorded = Locked<[HTTPRequest]>([])

  var requests: [HTTPRequest] { recorded.current }

  func send(_ request: HTTPRequest, onResult: @escaping (TransportOutcome) -> Void) {
    recorded.withLock { $0.append(request) }
    let body = request.lane == "lifecycle" ? "{\"accepted\":true,\"sessionId\":\"collector-1\"}" : "{\"accepted\":true}"
    onResult(.http(status: 202, body: body))
  }

  func close() {}
}

/// Answers every capture as the coordinator would, with a stand-in JPEG.
final class AnsweringCaptures: CaptureRequestSink {
  weak var host: EngineHost?
  private let frames: FrameHandleTable
  private let count = Locked(0)

  init(frames: FrameHandleTable) {
    self.frames = frames
  }

  var answered: Int { count.current }

  func onCaptureRequest(_ request: CaptureRequestEffect) {
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
    let frame = CapturedFrame(
      handle: frames.put(jpeg), width: 302, height: 656, contentHash: "sha-" + request.requestId, masked: true,
      byteLength: jpeg.count, captureMicros: 1000, dHash: "00ff00ff00ff00ff", structureSignature: "sig",
      maskCoverage: MaskCoverage(mode: .precise, reasons: []))
    let answer = CaptureAnswer.captured(
      requestId: request.requestId, frame: frame, boundaryRect: BoundaryRect(x: 0, y: 0, width: 402, height: 874),
      timings: CaptureTimingsMicros(readbackMicros: 500))
    count.withLock { $0 += 1 }
    host?.post(
      type: HostMessages.captureResult, inputJSON: CaptureResultJSON.encode(answer), at: SystemHostClock().now(),
      frameHandles: answer.frameHandles)
  }
}

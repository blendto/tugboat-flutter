#if canImport(UIKit)
import TugboatSessionEngine
import UIKit
import XCTest

@testable import Tugboat

/// BLE-618: the installation id file is read or written off the main thread
/// (on the engine queue), `start` does not wait for it, and the id is in
/// place in `engine.configure` before `session.start`, so before the first
/// `session_start` is sent. A refused start never touches the file. Real
/// engines; the collector (port 9) refuses connections.
final class InstallationIdOrderingTests: XCTestCase {
  private let recorder = EngineRecorder()
  private var root: URL!
  private var previousOpen: (() -> EngineTransport?)?
  private var previousStore: InstallationIdStore?

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("tb-order-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    previousOpen = TugboatRuntime.openTransport
    previousStore = TugboatRuntime.installationIds
    let recorder = self.recorder
    TugboatRuntime.openTransport = { recorder.open() }
  }

  override func tearDown() {
    TugboatRuntime.openTransport = previousOpen ?? { EngineBridge.open() }
    TugboatRuntime.installationIds = previousStore ?? .shared
    try? FileManager.default.removeItem(at: root)
  }

  private func config(version: String = "1.0", installationId: String = "") -> TugboatConfig {
    TugboatConfig(
      collector: .init(baseURL: URL(string: "http://127.0.0.1:9") ?? URL(fileURLWithPath: "/"), apiKey: "key"),
      app: .init(
        name: "Tests", version: version, buildNumber: "1", appId: "com.tugboat.tests", installationId: installationId),
      trackHostingControllers: false)
  }

  private func eventually(_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(30)
    while !condition() {
      if Date() > deadline { return false }
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return true
  }

  private func installationId(in configure: [String: Any]) -> String? {
    ((configure["host"] as? [String: Any])?["app"] as? [String: Any])?["installationId"] as? String
  }

  func testStartDoesNotWaitForTheDiskAndTheIdIsInConfigureBeforeSessionStart() throws {
    let gate = DispatchSemaphore(value: 0)
    let diskThread = Locked<Thread?>(nil)
    let root = self.root!
    TugboatRuntime.installationIds = InstallationIdStore(directory: {
      diskThread.withLock { $0 = Thread.current }
      gate.wait()
      return root
    })
    let runtime = TugboatRuntime.start(config: config(), sessionEpoch: 0, activationRequestId: nil)
    // `start` returned while the disk is still "slow": it never blocked on
    // it, and nothing has reached the engine.
    XCTAssertNotNil(runtime)
    XCTAssertTrue(recorder.messages.isEmpty)

    gate.signal()
    XCTAssertTrue(eventually { !recorder.inputs("session.start").isEmpty })
    XCTAssertFalse(diskThread.current?.isMainThread ?? true, "the file was read on the main thread")

    let types = recorder.messages.map { $0.type }
    let configureIndex = try XCTUnwrap(types.firstIndex(of: "engine.configure"))
    let startIndex = try XCTUnwrap(types.firstIndex(of: "session.start"))
    XCTAssertLessThan(configureIndex, startIndex)
    let id = try XCTUnwrap(installationId(in: recorder.inputs("engine.configure")[0]))
    XCTAssertFalse(id.isEmpty)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("tugboat/installation_id"), encoding: .utf8), id)
    runtime?.stop()
  }

  func testAHostIdWinsAndTheFileIsNeverCreated() throws {
    TugboatRuntime.installationIds = InstallationIdStore(directory: { self.root })
    let runtime = TugboatRuntime.start(config: config(installationId: "host-id"), sessionEpoch: 0, activationRequestId: nil)
    XCTAssertTrue(eventually { !recorder.inputs("session.start").isEmpty })
    XCTAssertEqual(installationId(in: recorder.inputs("engine.configure")[0]), "host-id")
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("tugboat/installation_id").path))
    runtime?.stop()
  }

  func testARefusedStartNeverTouchesTheFile() {
    TugboatRuntime.installationIds = InstallationIdStore(directory: { self.root })
    XCTAssertNil(TugboatRuntime.start(config: config(version: " "), sessionEpoch: 0, activationRequestId: nil))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("tugboat").path))
  }

  /// The session id the launch lines print is the one the engine mints for
  /// the seed (derived in the host so it exists before the engine answers).
  func testTheSessionIdForASeedIsTheEnginesOwn() throws {
    let seed = "11" + String(repeating: "11", count: 31)
    XCTAssertEqual(IdSeed.sessionId(seed), "session-f81644b2-12d3-462e-b98c-29d15b723874")
    XCTAssertEqual(
      IdSeed.sessionId(String((0..<32).map { String(format: "%02x", $0) }.joined())),
      "session-a9d6e500-293a-48bd-b8cb-e213d07ab71f")

    let bridge = try XCTUnwrap(EngineBridge.open())
    defer { bridge.close() }
    let app = TugboatConfig.App(name: "n", version: "1", buildNumber: "1", appId: "a", installationId: "i")
    let device = DeviceSnapshot(
      id: "d", model: nil, osVersion: nil, screenWidth: 1, screenHeight: 1, scale: 1,
      locale: LocaleSnapshot(language: "en", country: nil, script: nil), timezone: "UTC")
    let metadata = HostMetadata(app: app, device: device)
    let configure =
      "{\"type\":\"engine.configure\",\"input\":"
      + EngineConfiguration.build(config: config(), host: metadata, gesture: .uiKitDefault).json + "}"
    XCTAssertEqual(bridge.submit(Data(configure.utf8)).status, TB_SESSION_OK)
    let start =
      "{\"type\":\"session.start\",\"at\":{\"monoUs\":0,\"wallUs\":0},\"input\":"
      + SessionMessages.sessionStartInput(viewport: (1, 1), host: metadata, sessionEpoch: 0, idSeed: seed) + "}"
    let response = bridge.submit(Data(start.utf8))
    XCTAssertEqual(response.status, TB_SESSION_OK)
    XCTAssertTrue(response.text.contains("\"captureSessionId\":\"" + IdSeed.sessionId(seed) + "\""), response.text)
  }

  func testRacingStoresAdoptTheIdThatReachedDisk() {
    let root = self.root!
    let results = Locked<[String]>([])
    let group = DispatchGroup()
    let start = DispatchSemaphore(value: 0)
    for n in 1...6 {
      group.enter()
      DispatchQueue.global().async {
        start.wait()
        let id = InstallationIdStore(directory: { root }, mint: { "racer-\(n)" }).read()
        results.withLock { $0.append(id) }
        group.leave()
      }
    }
    for _ in 1...6 { start.signal() }
    group.wait()
    XCTAssertEqual(Set(results.current).count, 1)
    XCTAssertEqual(
      try? String(contentsOf: root.appendingPathComponent("tugboat/installation_id"), encoding: .utf8), results.current.first)
  }
}
#endif

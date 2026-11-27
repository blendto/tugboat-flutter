import Foundation
import XCTest

@testable import Tugboat

/// Records requests and answers only when the test calls `complete`
/// (UIKit- and engine-free, so the outbox tests also run on Linux).
final class OutboxRecordingSender: HTTPSender {
  private struct State {
    var requests: [HTTPRequest] = []
    var callbacks: [(TransportOutcome) -> Void] = []
    var closed = false
  }

  private let state = Locked(State())
  /// Runs inside `send`, for tests that look at the disk at send time.
  var onSend: ((HTTPRequest) -> Void)?

  var requests: [HTTPRequest] { state.current.requests }
  var closed: Bool { state.current.closed }

  func send(_ request: HTTPRequest, onResult: @escaping (TransportOutcome) -> Void) {
    state.withLock { (state: inout State) in
      state.requests.append(request)
      state.callbacks.append(onResult)
    }
    onSend?(request)
  }

  func complete(_ index: Int, _ outcome: TransportOutcome) {
    let callback = state.withLock { $0.callbacks[index] }
    callback(outcome)
  }

  func close() {
    state.withLock { $0.closed = true }
  }
}

/// A temporary outbox root, a settable wall clock, captured backoff
/// timers, and the log lines.
final class OutboxHarness {
  let root: URL
  let clock = Locked<Int64>(1_800_000_000_000)
  let scheduled = Locked([(delayMs: Int, work: () -> Void)]())
  let lines = Locked([String]())

  init() {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tugboat-outbox-tests-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("outbox/v1", isDirectory: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent())
  }

  /// A new outbox over the same directory: a new process.
  func outbox(epoch: String = Outbox.mintEpoch()) -> Outbox {
    Outbox(
      store: OutboxStore(root: root), processEpoch: epoch, wallMs: { [clock] in clock.current },
      log: { [lines] line in lines.withLock { $0.append(line) } },
      schedule: { [scheduled] delay, work in scheduled.withLock { $0.append((delay, work)) } })
  }

  func advance(ms: Int64) {
    clock.withLock { $0 += ms }
  }

  /// Entry directories on disk.
  var directories: [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
  }

  func entry(_ dir: String) -> [String: Any] {
    guard let data = try? Data(contentsOf: root.appendingPathComponent(dir).appendingPathComponent("entry.json")),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object
  }

  /// Rewrites `entry.json` of `dir` through `change`.
  func rewrite(_ dir: String, _ change: (inout [String: Any]) -> Void) throws {
    var object = entry(dir)
    change(&object)
    try JSONSerialization.data(withJSONObject: object)
      .write(to: root.appendingPathComponent(dir).appendingPathComponent("entry.json"))
  }

  func file(_ dir: String, _ name: String) -> Data? {
    try? Data(contentsOf: root.appendingPathComponent(dir).appendingPathComponent(name))
  }
}

enum OutboxRequests {
  static let context = OutboxContext(
    identityInput: Data("https://collector.test\ncom.example\nkey-1".utf8), bounds: .default, sdkVersion: "0.1.0")

  static func lifecycle(
    _ eventType: String = "session_start", session: String = "s1", triggeredAt: String = "2026-10-27T10:00:00.000Z",
    extra: String = "", id: String = "http-1"
  ) -> HTTPRequest {
    HTTPRequest(
      requestId: id, lane: "lifecycle", path: "/v1/sessions", timeoutMs: 15_000,
      body: .json(
        "{\"sessionId\":\"\(session)\",\"eventType\":\"\(eventType)\",\"triggeredAt\":\"\(triggeredAt)\"\(extra)}"))
  }

  static func events(_ ids: [String], session: String = "s1", id: String = "http-2") -> HTTPRequest {
    let events = ids.map { "{\"id\":\"\($0)\",\"sessionId\":\"\(session)\",\"eventType\":\"tap\"}" }
    return HTTPRequest(
      requestId: id, lane: "events", path: "/v1/events/batch", timeoutMs: 15_000,
      body: .json("{\"events\":[\(events.joined(separator: ","))]}"))
  }

  /// A frame chunk; frame `n` has handle `h<n>` and metadata `{"frameNo":n,…}`.
  static func frames(_ numbers: [Int], session: String = "s1", id: String = "http-3") -> HTTPRequest {
    let metadata = numbers.map { "{\"frameNo\":\($0),\"atMs\":1.50,\"note\":\"a,]}\\\"b\"}" }
    return HTTPRequest(
      requestId: id, lane: "frames", path: "/v1/frames", timeoutMs: 15_000,
      body: .multipart(
        fields: [
          FormField(name: "sessionId", value: session),
          FormField(name: "frameNos", value: numbers.map(String.init).joined(separator: ",")),
          FormField(name: "frameMetadata", value: "[\(metadata.joined(separator: ","))]"),
        ],
        frames: numbers.map { FramePart(handle: "h\($0)", filename: "\($0).jpg") }))
  }

  static func jpeg(_ handle: String) -> Data? {
    Data("jpeg-\(handle)".utf8)
  }
}

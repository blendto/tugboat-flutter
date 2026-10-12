import Foundation
import TugboatSessionEngine

@testable import Tugboat

/// A serial queue that stands in for `tugboat.engine` and lets fakes check
/// they run on it.
enum TestQueues {
  static let engineKey = DispatchSpecificKey<String>()

  static func engine() -> DispatchQueue {
    let queue = DispatchQueue(label: "test.tugboat.engine")
    queue.setSpecific(key: engineKey, value: "engine")
    return queue
  }

  static var onEngineQueue: Bool {
    DispatchQueue.getSpecific(key: engineKey) != nil
  }
}

/// Records every submitted message and answers from a queue of responses,
/// then with an empty `ok` response.
final class FakeEngineTransport: EngineTransport {
  private struct State {
    var queued: [EngineResponse] = []
    var submitted: [String] = []
    var submitsOnEngineQueue: [Bool] = []
    var inSubmit = false
    var overlappingSubmits = 0
    var closed = false
    var submittedAtClose: Int?
  }

  private let state = Locked(State())

  /// Called on the engine queue with each submitted message.
  var onSubmit: ((String) -> Void)?
  /// Called on the engine queue when the host destroys the handle.
  var onClose: (() -> Void)?

  var submitted: [String] { state.current.submitted }
  var submitsOnEngineQueue: [Bool] { state.current.submitsOnEngineQueue }
  var overlappingSubmits: Int { state.current.overlappingSubmits }
  var closed: Bool { state.current.closed }
  /// How many messages had been submitted when the handle was closed.
  var submittedAtClose: Int? { state.current.submittedAtClose }

  func enqueue(_ response: EngineResponse) {
    state.withLock { $0.queued.append(response) }
  }

  func submit(_ message: Data) -> EngineResponse {
    let text = String(decoding: message, as: UTF8.self)
    let onEngineQueue = TestQueues.onEngineQueue
    let response = state.withLock { (state: inout State) -> EngineResponse in
      if state.inSubmit {
        state.overlappingSubmits += 1
      }
      state.inSubmit = true
      state.submitted.append(text)
      state.submitsOnEngineQueue.append(onEngineQueue)
      return state.queued.isEmpty ? ok() : state.queued.removeFirst()
    }
    onSubmit?(text)
    state.withLock { $0.inSubmit = false }
    return response
  }

  func close() {
    state.withLock { (state: inout State) in
      state.closed = true
      state.submittedAtClose = state.submitted.count
    }
    onClose?()
  }
}

func ok(_ effects: String...) -> EngineResponse {
  response(TB_SESSION_OK, "{\"type\":\"test\",\"records\":[],\"effects\":[" + effects.joined(separator: ",") + "]}")
}

func response(_ status: tb_session_status, _ json: String) -> EngineResponse {
  EngineResponse(status: status, json: Data(json.utf8))
}

func failure(_ status: tb_session_status) -> EngineResponse {
  response(status, "{\"error\":{\"status\":\"\(String(cString: tb_session_status_name(status)))\",\"message\":\"test\"}}")
}

/// Records requests; answers only when the test calls `complete`.
final class FakeHTTPSender: HTTPSender {
  private struct State {
    var requests: [HTTPRequest] = []
    var callbacks: [(TransportOutcome) -> Void] = []
    var framesPresentAtSend: [Bool] = []
    var closed = false
  }

  private let state = Locked(State())
  private let frames: FrameHandleTable?

  init(frames: FrameHandleTable? = nil) {
    self.frames = frames
  }

  var requests: [HTTPRequest] { state.current.requests }
  /// Whether each multipart request's frame handles were still in the table when sent.
  var framesPresentAtSend: [Bool] { state.current.framesPresentAtSend }
  var closed: Bool { state.current.closed }

  func send(_ request: HTTPRequest, onResult: @escaping (TransportOutcome) -> Void) {
    var present: Bool?
    if let frames = frames, case let .multipart(_, parts) = request.body {
      present = parts.allSatisfy { frames.get($0.handle) != nil }
    }
    state.withLock { (state: inout State) in
      state.requests.append(request)
      state.callbacks.append(onResult)
      if let present = present {
        state.framesPresentAtSend.append(present)
      }
    }
  }

  func complete(_ index: Int, _ outcome: TransportOutcome) {
    let callback = state.withLock { $0.callbacks[index] }
    callback(outcome)
  }

  func close() {
    state.withLock { $0.closed = true }
  }
}

final class FakeClock: HostClock {
  private let time: Locked<HostTime>

  init(monoUs: Int64 = 1_000_000, wallUs: Int64 = 1_791_712_345_678_901) {
    time = Locked(HostTime(monoUs: monoUs, wallUs: wallUs))
  }

  func set(monoUs: Int64) {
    time.withLock { $0 = HostTime(monoUs: monoUs, wallUs: $0.wallUs) }
  }

  func now() -> HostTime {
    time.current
  }
}

/// Parses one JSON object for assertions.
func jsonObject(_ text: String) -> [String: Any] {
  guard let data = text.data(using: .utf8),
    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else {
    return [:]
  }
  return object
}

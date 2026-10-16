import Foundation

/// Where an open session's evidence goes: the engine host. Any thread.
protocol EvidenceSink: AnyObject {
  /// False once the host closed or disabled itself.
  var isRunning: Bool { get }
  func postEvidence(type: String, inputJSON: String, at: HostTime)
}

extension EngineHost: EvidenceSink {
  func postEvidence(type: String, inputJSON: String, at: HostTime) {
    post(type: type, inputJSON: inputJSON, at: at)
  }
}

/// Admits coded events and network calls into the running session.
///
/// `start` opens it and `stop` closes it, on the main thread. Admission is
/// decided on the calling thread when `record` or `beginNetworkCall` runs,
/// and so is the time, from the host clock the engine's `at` uses. The
/// message then hops to the main thread (`schedule`), so it keeps its order
/// with `start`, `setUserId`, and `stop`, and is dropped there when its
/// session is no longer the open one or the host stopped.
final class EvidenceChannel: @unchecked Sendable {
  static let shared = EvidenceChannel()

  private struct Session {
    let generation: Int
    let sink: EvidenceSink
  }

  private struct State {
    var generation = 0
    var open: Session?
  }

  private let state = Locked(State())
  private let clock: HostClock
  private let schedule: (@escaping () -> Void) -> Void

  init(clock: HostClock = SystemHostClock(), schedule: @escaping (@escaping () -> Void) -> Void = EvidenceChannel.onMain) {
    self.clock = clock
    self.schedule = schedule
  }

  /// Opens a new session on `sink`; main thread.
  func open(_ sink: EvidenceSink) {
    state.withLock { (state: inout State) in
      state.generation += 1
      state.open = Session(generation: state.generation, sink: sink)
    }
  }

  /// Closes the session; posts already scheduled for it are dropped.
  func close() {
    state.withLock { $0.open = nil }
  }

  /// The open session's generation when it accepts evidence; any thread.
  func admit() -> Int? {
    guard let open = state.current.open, open.sink.isRunning else { return nil }
    return open.generation
  }

  func now() -> HostTime {
    clock.now()
  }

  /// Posts `inputJSON` on the main thread if session `generation` is still
  /// open and its host still runs.
  func submit(type: String, inputJSON: String, at: HostTime, generation: Int) {
    schedule { [state] in
      guard let open = state.current.open, open.generation == generation, open.sink.isRunning else { return }
      open.sink.postEvidence(type: type, inputJSON: inputJSON, at: at)
    }
  }

  static func onMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }
}

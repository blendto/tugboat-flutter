import Foundation
import TugboatSessionEngine

/// Owns one engine handle (`transport`) and drives it from one serial queue.
/// `post*` may be called from any thread; every submit, response, and effect
/// runs on that queue, in post order.
///
/// Failures never reach the caller. A non-`ok` status is logged, the message
/// dropped, and its frame handles released; `maxConsecutiveInternalErrors`
/// `internal_error`s in a row shut the host down for good.
final class EngineHost {
  static let defaultMaxConsecutiveInternalErrors = 3

  private let transport: EngineTransport
  private let queue: DispatchQueue
  private let http: HTTPSender
  private let frames: FrameHandleTable
  private let clock: HostClock
  private let maxConsecutiveInternalErrors: Int
  private let onShutDown: () -> Void

  /// Gates new posts; any thread reads it.
  private let accepting = Locked(true)

  // Engine queue only from here on.
  private var active = true
  private var consecutiveInternalErrors = 0

  private lazy var timers: TimerExecutor = TimerExecutor(queue: self.queue) { [weak self] timerId, atMonoUs in
    self?.timerFired(timerId: timerId, atMonoUs: atMonoUs)
  }

  private lazy var effects: EffectDispatcher = EffectDispatcher(
    timers: self.timers,
    http: self.http,
    frames: self.frames,
    post: { [weak self] type, inputJSON in self?.postNow(type: type, inputJSON: inputJSON) }
  )

  init(
    transport: EngineTransport,
    queue: DispatchQueue,
    http: HTTPSender,
    frames: FrameHandleTable,
    clock: HostClock = SystemHostClock(),
    maxConsecutiveInternalErrors: Int = EngineHost.defaultMaxConsecutiveInternalErrors,
    onShutDown: @escaping () -> Void = {}
  ) {
    self.transport = transport
    self.queue = queue
    self.http = http
    self.frames = frames
    self.clock = clock
    self.maxConsecutiveInternalErrors = maxConsecutiveInternalErrors
    self.onShutDown = onShutDown
  }

  /// Starts a host on a new `tugboat.engine` queue; the host owns `transport`.
  static func start(config: HostConfig, transport: EngineTransport, frames: FrameHandleTable) -> EngineHost {
    EngineHost(
      transport: transport,
      queue: DispatchQueue(label: "tugboat.engine", qos: .utility),
      http: HTTPExecutor(config: config, frameBytes: { frames.get($0) }),
      frames: frames
    )
  }

  /// False after `close` or after the host disabled itself.
  var isRunning: Bool {
    accepting.current
  }

  /// Submits one fact that happened at `at`. `frameHandles` are handles the
  /// message passes to the engine; they are released if it is rejected.
  func post(type: String, inputJSON: String, at: HostTime, frameHandles: [String] = []) {
    let message = EngineMessage(type: type, inputJSON: inputJSON, at: at, frameHandles: frameHandles)
    enqueue(json: message.json, frameHandles: frameHandles)
  }

  /// Submits `messages` as one all-or-nothing `batch`; each keeps its own `at`.
  func postBatch(_ messages: [EngineMessage]) {
    guard !messages.isEmpty else { return }
    enqueue(json: EngineMessage.batchJSON(messages), frameHandles: messages.flatMap { $0.frameHandles })
  }

  /// Submits a message the engine takes without `at`: `engine.configure`,
  /// queries (`session.snapshot`), stateless messages.
  func postUntimed(type: String, inputJSON: String) {
    enqueue(json: EngineMessage(type: type, inputJSON: inputJSON, at: nil).json, frameHandles: [])
  }

  /// Submits `engine.dispose`, then cancels timers, closes IO, destroys the
  /// handle, and frees frames, after already-posted work.
  func close() {
    accepting.withLock { $0 = false }
    queue.async { self.shutDown() }
  }

  private func postNow(type: String, inputJSON: String) {
    post(type: type, inputJSON: inputJSON, at: clock.now())
  }

  /// The engine ignores a fire stamped before the timer's deadline as stale,
  /// so the stamp is never earlier than `atMonoUs`.
  private func timerFired(timerId: String, atMonoUs: Int64) {
    let now = clock.now()
    let at = HostTime(monoUs: max(now.monoUs, atMonoUs), wallUs: now.wallUs)
    post(type: HostMessages.timerFired, inputJSON: HostMessages.timerFiredInput(timerId: timerId), at: at)
  }

  private func enqueue(json: String, frameHandles: [String]) {
    guard accepting.current else {
      release(frameHandles)
      return
    }
    queue.async {
      if self.active {
        self.process(json: json, frameHandles: frameHandles)
      } else {
        self.release(frameHandles)
      }
    }
  }

  private func process(json: String, frameHandles: [String]) {
    let response = transport.submit(Data(json.utf8))
    if !accept(response) {
      release(frameHandles)
    }
  }

  /// Runs the effects of an `ok` response; false when the engine rejected
  /// the message.
  private func accept(_ response: EngineResponse) -> Bool {
    if response.status == TB_SESSION_INTERNAL_ERROR {
      onInternalError(response)
      return false
    }
    consecutiveInternalErrors = 0
    guard response.status == TB_SESSION_OK else {
      HostLog.warning("engine dropped a message (\(response.statusName)): \(response.text)")
      return false
    }
    let parsed: [Effect]
    do {
      parsed = try EffectParser.parse(response.json)
    } catch {
      HostLog.error("unreadable engine response: \(error)")
      return true
    }
    for effect in parsed {
      effects.dispatch(effect)
    }
    return true
  }

  private func onInternalError(_ response: EngineResponse) {
    consecutiveInternalErrors += 1
    HostLog.error("engine internal_error (\(consecutiveInternalErrors) in a row): \(response.text)")
    guard consecutiveInternalErrors >= maxConsecutiveInternalErrors else { return }
    HostLog.error("disabling the Tugboat engine host for this process")
    accepting.withLock { $0 = false }
    shutDown()
  }

  private func release(_ frameHandles: [String]) {
    for handle in frameHandles {
      frames.release(handle)
    }
  }

  private func shutDown() {
    guard active else { return }
    active = false
    dispose()
    timers.cancelAll()
    http.close()
    transport.close()
    frames.close()
    onShutDown()
  }

  /// Lets the engine report undelivered work before its handle goes. Its
  /// effects run as usual except that no new IO or timer starts: `http.send`
  /// and `timer.schedule` are dropped, `frame.release` is honoured. An engine
  /// without `engine.dispose` (before phase 3b) answers
  /// `unsupported_message`, which is logged and otherwise ignored.
  private func dispose() {
    let message = EngineMessage(type: HostMessages.engineDispose, inputJSON: "{}", at: clock.now())
    let response = transport.submit(Data(message.json.utf8))
    guard response.status == TB_SESSION_OK else {
      HostLog.warning("engine.dispose not accepted (\(response.statusName)); destroying the handle")
      return
    }
    guard let parsed = try? EffectParser.parse(response.json) else { return }
    for effect in parsed {
      switch effect {
      case .httpSend, .timerSchedule:
        continue
      default:
        effects.dispatch(effect)
      }
    }
  }
}

import Foundation

/// The activation request and lifecycle state, Flutter's
/// `TugboatLifecycleNotifier` (`lifecycle.dart`) on native: `activate`,
/// `deactivate`, and `stop` change it on the calling thread, so the new
/// state and id are visible at once from any thread; `ActivationDriver`
/// then makes the session match it on the main thread.
///
/// `requestEpoch` counts requests. The driver remembers the epoch its
/// session was started for, and a `mark…` call for an epoch that is no
/// longer current is ignored, as in Flutter.
final class ActivationState: @unchecked Sendable {
  struct Snapshot: Equatable {
    var state: TugboatLifecycleState = .dormant
    var activationRequestId: String?
    /// `activate` sets true, `deactivate` false; nil lets
    /// `TugboatConfig.enabled` decide. Cleared by `stop`.
    var captureOverride: Bool?
    var requestEpoch = 0

    /// Flutter's `isActivated`.
    var isActivated: Bool {
      activationRequestId != nil && state != .dormant
    }

    func shouldCapture(configEnabled: Bool) -> Bool {
      captureOverride ?? configEnabled
    }
  }

  private let locked = Locked(Snapshot())

  /// Tests: called after every change with the new snapshot, outside the
  /// lock, on the thread that made it.
  var onChange: ((Snapshot) -> Void)?

  var current: Snapshot {
    locked.current
  }

  /// Requests a session for `activationRequestId`; false (nothing to do)
  /// when that id is already starting or active.
  func activate(_ activationRequestId: String) -> Bool {
    update { snapshot in
      let sameRequest = snapshot.activationRequestId == activationRequestId && snapshot.captureOverride == true
        && (snapshot.state == .starting || snapshot.state == .active)
      if sameRequest { return false }
      snapshot.requestEpoch += 1
      snapshot.activationRequestId = activationRequestId
      snapshot.captureOverride = true
      snapshot.state = .starting
      return true
    }
  }

  /// Requests no session until the next `activate`; false (nothing to do)
  /// when dormant with no request. `fence` runs under the lock with the
  /// change, so a session the driver opens for an older request cannot
  /// take evidence after it (`openIfCurrent`).
  func deactivate(fence: () -> Void) -> Bool {
    update { snapshot in
      if snapshot.state == .dormant && snapshot.activationRequestId == nil { return false }
      snapshot.requestEpoch += 1
      snapshot.activationRequestId = nil
      snapshot.captureOverride = false
      snapshot.state = .stopping
      fence()
      return true
    }
  }

  /// `Tugboat.stop`: forgets the request and the override. `stopping`
  /// unless already dormant; the driver marks it dormant once the session
  /// ended.
  func reset(fence: () -> Void) {
    update { snapshot in
      snapshot.requestEpoch += 1
      snapshot.activationRequestId = nil
      snapshot.captureOverride = nil
      if snapshot.state != .dormant {
        snapshot.state = .stopping
      }
      fence()
      return true
    }
  }

  /// A session for `epoch` is being set up (configuration-enabled start).
  func markStarting(_ epoch: Int) {
    update { snapshot in
      guard epoch == snapshot.requestEpoch, snapshot.state == .dormant else { return false }
      snapshot.state = .starting
      return true
    }
  }

  /// The session for `epoch` is running.
  func markActive(_ epoch: Int) {
    update { snapshot in
      guard epoch == snapshot.requestEpoch, snapshot.state == .starting else { return false }
      snapshot.state = .active
      return true
    }
  }

  /// No session runs for `epoch`. A request that still wants one (an
  /// `activate` not yet applied) keeps `starting`, as Flutter's
  /// `markDormant`.
  func markDormant(_ epoch: Int) {
    update { snapshot in
      guard epoch == snapshot.requestEpoch else { return false }
      if snapshot.captureOverride == true {
        guard snapshot.state == .stopping else { return false }
        snapshot.state = .starting
        return true
      }
      guard snapshot.state != .dormant else { return false }
      snapshot.state = .dormant
      return true
    }
  }

  /// The session for `epoch` could not start (logged by the runtime).
  /// The request is kept, so the same `activate` tries again.
  func markFailed(_ epoch: Int) {
    update { snapshot in
      guard epoch == snapshot.requestEpoch, snapshot.state != .dormant else { return false }
      snapshot.state = .dormant
      return true
    }
  }

  /// Runs `open` under the lock if `epoch` is still the current request;
  /// returns whether it ran.
  func openIfCurrent(_ epoch: Int, _ open: () -> Void) -> Bool {
    locked.withLock { snapshot in
      guard snapshot.requestEpoch == epoch else { return false }
      open()
      return true
    }
  }

  @discardableResult
  private func update(_ body: (inout Snapshot) -> Bool) -> Bool {
    let changed = locked.withLock { (snapshot: inout Snapshot) -> Snapshot? in
      body(&snapshot) ? snapshot : nil
    }
    if let changed = changed {
      onChange?(changed)
    }
    return changed != nil
  }
}

/// Makes the running session match `ActivationState` and the stored
/// configuration, as Flutter's activation gate (`_syncCaptureFlag`) does:
/// starts a session when one is wanted and none runs for the current
/// request, and ends it when none is wanted. Ending always goes through
/// `end` (the runtime's `stop`: `session.end`, then the background drain),
/// and a new id ends the old session before starting the next.
///
/// Main thread only. `Session` is the runtime in the SDK and a fake in
/// tests.
final class ActivationDriver<Session: AnyObject> {
  typealias Begin = (_ config: TugboatConfig, _ activationRequestId: String?) -> Session?

  private let state: ActivationState
  private let begin: Begin
  private let open: (Session) -> Void
  private let end: (Session) -> Void

  private(set) var config: TugboatConfig?
  private(set) var session: Session?
  private var sessionEpoch: Int?

  /// `begin` configures an engine and posts `session.start` (nil when it
  /// cannot); `open` lets the session take evidence; `end` ends it.
  init(
    state: ActivationState, begin: @escaping Begin, open: @escaping (Session) -> Void,
    end: @escaping (Session) -> Void
  ) {
    self.state = state
    self.begin = begin
    self.open = open
    self.end = end
  }

  /// Stores `config` and applies it; false when one is already stored.
  func configure(_ config: TugboatConfig) -> Bool {
    guard self.config == nil else { return false }
    self.config = config
    reconcile()
    return true
  }

  /// Ends the session and forgets the configuration (`Tugboat.stop`).
  func stop() {
    config = nil
    reconcile()
  }

  func reconcile() {
    let snapshot = state.current
    let epoch = snapshot.requestEpoch
    guard let config = config, snapshot.shouldCapture(configEnabled: config.enabled) else {
      endSession()
      state.markDormant(epoch)
      return
    }
    if session != nil && sessionEpoch == epoch { return }
    endSession()
    state.markStarting(epoch)
    guard let started = begin(config, snapshot.activationRequestId) else {
      state.markFailed(epoch)
      return
    }
    session = started
    sessionEpoch = epoch
    // A request made on another thread since the snapshot (`deactivate`,
    // `stop`, a new id) wins: the session is never opened, and it is ended
    // (or replaced) now, in this main-thread turn, rather than by that
    // request's queued reconcile.
    if state.openIfCurrent(epoch, { open(started) }) {
      state.markActive(epoch)
    } else {
      reconcile()
    }
  }

  private func endSession() {
    guard let running = session else { return }
    session = nil
    sessionEpoch = nil
    end(running)
  }
}

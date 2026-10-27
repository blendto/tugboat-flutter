#if canImport(UIKit)
import Foundation

/// Device Farm launch / health lines for human and future log scraping.
/// Emits at most once per process: LAUNCH at the first session start (a
/// dormant launch prints it when `activate` starts the session), HEALTH ten
/// seconds later with the lifecycle state at that moment (`lifecycle`, plus
/// `activationRequestId` when set; no `captureSessionId` while dormant).
/// HEALTH outlives the session that armed it (`deactivate` or a new
/// activation id does not cancel it); `Tugboat.stop()` before the ten-second
/// mark does (`stop()`).
final class LaunchCorrelation {
  /// The lifecycle as HEALTH reports it.
  typealias Lifecycle = () -> (state: TugboatLifecycleState, activationRequestId: String?)

  private static var processLaunchLogged = false
  private static var firstSessionWallUs: Int64 = 0
  /// Main queue only.
  private static var pendingHealth: (work: DispatchWorkItem, cancel: (DispatchWorkItem) -> Void)?

  private let sessionWallUs: Int64
  private let lifecycle: Lifecycle
  private let schedule: (_ delay: TimeInterval, _ block: @escaping () -> Void) -> DispatchWorkItem
  private let cancel: (_ work: DispatchWorkItem) -> Void
  private let emit: (String) -> Void

  private let queue = DispatchQueue.main

  init(
    sessionWallUs: Int64,
    lifecycle: @escaping Lifecycle,
    schedule: @escaping (_ delay: TimeInterval, _ block: @escaping () -> Void) -> DispatchWorkItem = LaunchCorrelation.defaultSchedule,
    cancel: @escaping (_ work: DispatchWorkItem) -> Void = { $0.cancel() },
    emit: @escaping (String) -> Void = { HostLog.launch($0) }
  ) {
    self.sessionWallUs = sessionWallUs
    self.lifecycle = lifecycle
    self.schedule = schedule
    self.cancel = cancel
    self.emit = emit
  }

  func startIfNeeded() {
    startIfNeeded(parsed: LaunchOptions.fromProcessInfo())
  }

  func startIfNeeded(parsed options: LaunchOptions?) {
    queue.async {
      guard !Self.processLaunchLogged, let options = options else { return }
      Self.processLaunchLogged = true
      Self.firstSessionWallUs = self.sessionWallUs
      self.emit(options.launchLine(sessionWallUs: self.sessionWallUs))
      // Holds what HEALTH needs, not this object: the session may be gone.
      let lifecycle = self.lifecycle
      let emit = self.emit
      var fired = false
      let work = self.schedule(10) {
        fired = true
        Self.pendingHealth = nil
        guard Self.processLaunchLogged else { return }
        let reading = lifecycle()
        emit(
          LaunchOptions.healthLine(
            lifecycle: reading.state.rawValue, activationRequestId: reading.activationRequestId,
            sessionWallUs: Self.firstSessionWallUs))
      }
      if !fired {
        Self.pendingHealth = (work, self.cancel)
      }
    }
  }

  /// Cancels a HEALTH line not yet logged (`Tugboat.stop()`).
  func stop() {
    LaunchCorrelation.cancelHealth()
  }

  /// Cancels a HEALTH line not yet logged (`Tugboat.stop()`); any thread.
  static func cancelHealth() {
    DispatchQueue.main.async {
      guard let pending = pendingHealth else { return }
      pendingHealth = nil
      pending.cancel(pending.work)
    }
  }

  static func resetForTests() {
    processLaunchLogged = false
    firstSessionWallUs = 0
    pendingHealth = nil
  }

  private static func defaultSchedule(_ delay: TimeInterval, block: @escaping () -> Void) -> DispatchWorkItem {
    let work = DispatchWorkItem(block: block)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    return work
  }
}
#endif

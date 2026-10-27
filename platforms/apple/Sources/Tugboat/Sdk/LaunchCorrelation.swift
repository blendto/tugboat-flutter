#if canImport(UIKit)
import Foundation

/// Device Farm launch / health lines for human and future log scraping, as
/// the Flutter host prints them at configuration time. When the launch
/// inputs request capture, the first accepted `Tugboat.start` logs
/// `TUGBOAT_LAUNCH` at once, whatever the lifecycle, and `TUGBOAT_HEALTH`
/// ten seconds later; at most one of each per process. Both read the
/// lifecycle when they print: `captureSessionId` is the running session's
/// id (left out when no session runs), and HEALTH's `lifecycle` and
/// `activationRequestId` are the state and request at that moment. Only
/// `Tugboat.stop()` before the ten-second mark cancels HEALTH (`stop()`).
final class LaunchCorrelation {
  /// What the lines report, read when each prints.
  struct Reading {
    let state: TugboatLifecycleState
    let activationRequestId: String?
    /// The running session's start (`session.start` wall clock); nil when
    /// no session runs.
    let sessionWallUs: Int64?
  }

  typealias Lifecycle = () -> Reading

  private static var processLaunchLogged = false
  /// Main queue only.
  private static var pendingHealth: (work: DispatchWorkItem, cancel: (DispatchWorkItem) -> Void)?

  private let lifecycle: Lifecycle
  private let schedule: (_ delay: TimeInterval, _ block: @escaping () -> Void) -> DispatchWorkItem
  private let cancel: (_ work: DispatchWorkItem) -> Void
  private let emit: (String) -> Void

  private let queue = DispatchQueue.main

  init(
    lifecycle: @escaping Lifecycle,
    schedule: @escaping (_ delay: TimeInterval, _ block: @escaping () -> Void) -> DispatchWorkItem = LaunchCorrelation.defaultSchedule,
    cancel: @escaping (_ work: DispatchWorkItem) -> Void = { $0.cancel() },
    emit: @escaping (String) -> Void = { HostLog.launch($0) }
  ) {
    self.lifecycle = lifecycle
    self.schedule = schedule
    self.cancel = cancel
    self.emit = emit
  }

  func startIfNeeded(parsed options: LaunchOptions?) {
    queue.async {
      guard !Self.processLaunchLogged, let options = options else { return }
      Self.processLaunchLogged = true
      self.emit(options.launchLine(sessionWallUs: self.lifecycle().sessionWallUs))
      // Holds what HEALTH needs, not this object.
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
            sessionWallUs: reading.sessionWallUs))
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
    pendingHealth = nil
  }

  private static func defaultSchedule(_ delay: TimeInterval, block: @escaping () -> Void) -> DispatchWorkItem {
    let work = DispatchWorkItem(block: block)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    return work
  }
}
#endif

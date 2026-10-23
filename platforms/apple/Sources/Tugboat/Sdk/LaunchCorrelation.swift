#if canImport(UIKit)
import Foundation

/// Device Farm launch / health lines for human and future log scraping. Emits
/// at most once per process (first `start()` wins).
final class LaunchCorrelation {
  private static var processLaunchLogged = false
  private static var firstSessionWallUs: Int64 = 0

  private let sessionWallUs: Int64
  private let isEngineActive: () -> Bool
  private let schedule: (_ delay: TimeInterval, _ block: @escaping () -> Void) -> DispatchWorkItem
  private let cancel: (_ work: DispatchWorkItem) -> Void
  private let emit: (String) -> Void

  private var healthWork: DispatchWorkItem?
  private let queue = DispatchQueue.main

  init(
    sessionWallUs: Int64,
    isEngineActive: @escaping () -> Bool,
    schedule: @escaping (_ delay: TimeInterval, _ block: @escaping () -> Void) -> DispatchWorkItem = LaunchCorrelation.defaultSchedule,
    cancel: @escaping (_ work: DispatchWorkItem) -> Void = { $0.cancel() },
    emit: @escaping (String) -> Void = { HostLog.launch($0) }
  ) {
    self.sessionWallUs = sessionWallUs
    self.isEngineActive = isEngineActive
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
      let work = self.schedule(10) { [weak self] in self?.logHealth() }
      self.healthWork = work
    }
  }

  func stop() {
    queue.async {
      if let work = self.healthWork {
        self.cancel(work)
        self.healthWork = nil
      }
    }
  }

  private func logHealth() {
    healthWork = nil
    guard Self.processLaunchLogged else { return }
    let lifecycle = isEngineActive() ? "active" : "dormant"
    emit(LaunchOptions.healthLine(lifecycle: lifecycle, sessionWallUs: Self.firstSessionWallUs))
  }

  static func resetForTests() {
    processLaunchLogged = false
    firstSessionWallUs = 0
  }

  private static func defaultSchedule(_ delay: TimeInterval, block: @escaping () -> Void) -> DispatchWorkItem {
    let work = DispatchWorkItem(block: block)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    return work
  }
}
#endif

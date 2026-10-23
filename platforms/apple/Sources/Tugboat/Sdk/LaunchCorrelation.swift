#if canImport(UIKit)
import Foundation
import os.log

/// Device Farm launch / health lines for human and future log scraping.
final class LaunchCorrelation {
  private static let log = OSLog(subsystem: "com.gettugboat.sdk", category: "launch")

  private let sessionWallUs: Int64?
  private let schedule: (_ delay: TimeInterval, _ block: @escaping () -> Void) -> DispatchWorkItem
  private let cancel: (_ work: DispatchWorkItem) -> Void
  private let emit: (String) -> Void

  private var launchLogged = false
  private var healthWork: DispatchWorkItem?
  private var processLifecycle = "resumed"
  private let queue = DispatchQueue.main

  init(
    sessionWallUs: Int64?,
    schedule: @escaping (_ delay: TimeInterval, _ block: @escaping () -> Void) -> DispatchWorkItem = LaunchCorrelation.defaultSchedule,
    cancel: @escaping (_ work: DispatchWorkItem) -> Void = { $0.cancel() },
    emit: @escaping (String) -> Void = { line in os_log("%{public}@", log: LaunchCorrelation.log, type: .default, line as NSString) }
  ) {
    self.sessionWallUs = sessionWallUs
    self.schedule = schedule
    self.cancel = cancel
    self.emit = emit
  }

  func onProcessLifecycle(_ state: String) {
    queue.async { self.processLifecycle = state }
  }

  func startIfNeeded() {
    queue.async {
      guard !self.launchLogged, let options = LaunchOptions.fromProcessInfo() else { return }
      self.launchLogged = true
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
    guard let wallUs = sessionWallUs else { return }
    let lifecycle = Self.healthLifecycle(processLifecycle)
    emit(LaunchOptions.healthLine(lifecycle: lifecycle, sessionWallUs: wallUs))
  }

  static func healthLifecycle(_ appLifecycleState: String) -> String {
    appLifecycleState == "resumed" ? "active" : appLifecycleState
  }

  private static func defaultSchedule(_ delay: TimeInterval, block: @escaping () -> Void) -> DispatchWorkItem {
    let work = DispatchWorkItem(block: block)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    return work
  }
}
#endif

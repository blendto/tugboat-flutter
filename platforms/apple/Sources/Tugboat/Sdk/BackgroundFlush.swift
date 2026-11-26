#if canImport(UIKit)
import UIKit

/// The system's background tasks as the SDK uses them; tests replace
/// `TugboatRuntime.backgroundTasks`.
protocol BackgroundTasks: AnyObject {
  /// Asks for time to finish `name` in the background; nil when none was
  /// granted or the process cannot ask (an app extension). `expired` runs
  /// on the main thread if the time runs out first. Main thread.
  func begin(name: String, expired: @escaping () -> Void) -> UIBackgroundTaskIdentifier?
  /// Any thread.
  func end(_ task: UIBackgroundTaskIdentifier)
}

/// `UIApplication`'s background tasks. In an app extension, where there is
/// no shared application, nothing is begun.
final class ApplicationBackgroundTasks: BackgroundTasks {
  private let application = Locked<UIApplication?>(nil)

  func begin(name: String, expired: @escaping () -> Void) -> UIBackgroundTaskIdentifier? {
    guard Bundle.main.bundleURL.pathExtension != "appex" else { return nil }
    let app = UIApplication.shared
    application.withLock { $0 = app }
    let task = app.beginBackgroundTask(withName: name, expirationHandler: expired)
    return task == .invalid ? nil : task
  }

  /// `endBackgroundTask` may be called from any thread.
  func end(_ task: UIBackgroundTaskIdentifier) {
    application.current?.endBackgroundTask(task)
  }
}

/// Keeps the process running for one background flush (W11 design section
/// 3): after `didEnterBackground` returns, iOS may suspend the app, and the
/// flush's requests reach the outbox only through the engine and outbox
/// queues. The task is ended exactly once: when `flush` calls its `done`
/// (any thread), or when the system expires it, whichever comes first.
final class BackgroundFlush {
  static let taskName = "Tugboat background flush"

  private enum State {
    case pending
    case running(UIBackgroundTaskIdentifier)
    case ended
  }

  private let tasks: BackgroundTasks
  private let state = Locked(State.pending)

  private init(tasks: BackgroundTasks) {
    self.tasks = tasks
  }

  /// Begins a task, then runs `flush`. Main thread. If no task can be
  /// begun the flush still runs, unprotected.
  static func run(tasks: BackgroundTasks, flush: (_ done: @escaping () -> Void) -> Void) {
    let run = BackgroundFlush(tasks: tasks)
    let task = tasks.begin(name: taskName) { run.end(reason: "expired") }
    run.started(task)
    flush { run.end(reason: nil) }
  }

  private func started(_ task: UIBackgroundTaskIdentifier?) {
    let endNow = state.withLock { (state: inout State) -> Bool in
      guard case .pending = state else { return true }
      guard let task = task else {
        state = .ended
        return false
      }
      state = .running(task)
      return false
    }
    // Expired before `begin` returned: end the task it returned.
    if endNow, let task = task { tasks.end(task) }
  }

  private func end(reason: String?) {
    let task = state.withLock { (state: inout State) -> UIBackgroundTaskIdentifier? in
      defer { state = .ended }
      if case let .running(task) = state { return task }
      return nil
    }
    guard let task = task else { return }
    if let reason = reason {
      HostLog.warning("background flush \(reason) before its writes landed")
    }
    tasks.end(task)
  }
}
#endif

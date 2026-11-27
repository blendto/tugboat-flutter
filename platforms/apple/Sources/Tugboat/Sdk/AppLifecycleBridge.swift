#if canImport(UIKit)
import UIKit

/// Application lifecycle notifications to the engine's `app.lifecycle`
/// states, in the order Flutter's `AppLifecycleState` arrives on iOS:
///
/// | Notification | `app.lifecycle.state` |
/// | --- | --- |
/// | `didBecomeActive` | `resumed` (forced `lifecycle` capture, `app_foregrounded`) |
/// | `willResignActive` | `inactive` |
/// | `didEnterBackground` | `paused` (teardown, background flush) |
/// | `willEnterForeground` | `inactive` |
/// | `willTerminate` | `detached` (ends the session) |
///
/// The application notifications aggregate every scene, so a SwiftUI app
/// with several windows reports the process, not each scene. Starting while
/// the app is already active posts `resumed` once, as Flutter reports
/// `resumed` at launch and the Android bridge replays its current state, so
/// a launch records `app_foregrounded`; a start before the app is active
/// gets it from `didBecomeActive`. Main thread only; each fact is stamped
/// when its notification arrives.
final class AppLifecycleBridge {
  /// The state after which the engine has ended the session.
  static let detached = "detached"
  /// The state posted when the app enters the background.
  static let paused = "paused"

  static let mapping: [(name: Notification.Name, state: String)] = [
    (UIApplication.didBecomeActiveNotification, "resumed"),
    (UIApplication.willResignActiveNotification, "inactive"),
    (UIApplication.didEnterBackgroundNotification, paused),
    (UIApplication.willEnterForegroundNotification, "inactive"),
    (UIApplication.willTerminateNotification, detached),
  ]

  private let center: NotificationCenter
  private let post: (_ state: String) -> Void
  private let isActive: () -> Bool
  private var tokens: [NSObjectProtocol] = []

  init(
    center: NotificationCenter = .default,
    isActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active },
    post: @escaping (_ state: String) -> Void
  ) {
    self.center = center
    self.isActive = isActive
    self.post = post
  }

  func start() {
    guard tokens.isEmpty else { return }
    tokens = AppLifecycleBridge.mapping.map { entry in
      center.addObserver(forName: entry.name, object: nil, queue: nil) { [post] _ in post(entry.state) }
    }
    if isActive() { post("resumed") }
  }

  func stop() {
    tokens.forEach(center.removeObserver)
    tokens.removeAll()
  }
}
#endif

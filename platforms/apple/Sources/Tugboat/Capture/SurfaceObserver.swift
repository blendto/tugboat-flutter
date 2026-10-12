#if canImport(UIKit)
import UIKit

/// Feeds the key window's size to `SurfaceReporter` when it may have
/// changed: at start, when a window becomes key, when the app becomes
/// active, and on device rotation (again after the rotation animation, when
/// the window has its new bounds). Every capture also reports the size it
/// starts with (`CaptureCoordinator`), so a change these miss is reported
/// before the next frame. Main thread only.
final class SurfaceObserver {
  /// Longer than UIKit's rotation animation (about 0.4 s).
  static let settleDelay: TimeInterval = 0.6

  private let reporter: SurfaceReporter
  private let center: NotificationCenter
  private let window: () -> UIWindow?
  private var tokens: [NSObjectProtocol] = []

  init(reporter: SurfaceReporter, center: NotificationCenter = .default, window: @escaping () -> UIWindow? = { KeyWindow.current() }) {
    self.reporter = reporter
    self.center = center
    self.window = window
  }

  func start() {
    guard tokens.isEmpty else { return }
    // Balanced in `stop`; UIKit counts these calls.
    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    let names = [
      UIWindow.didBecomeKeyNotification,
      UIApplication.didBecomeActiveNotification,
      UIDevice.orientationDidChangeNotification,
    ]
    tokens = names.map { name in
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.check()
        DispatchQueue.main.asyncAfter(deadline: .now() + SurfaceObserver.settleDelay) { self?.check() }
      }
    }
    check()
  }

  func stop() {
    guard !tokens.isEmpty else { return }
    tokens.forEach(center.removeObserver)
    tokens.removeAll()
    UIDevice.current.endGeneratingDeviceOrientationNotifications()
  }

  /// Reports `geometry` when it differs from the last report.
  func report(_ geometry: CaptureGeometry) {
    reporter.observe(geometry.boundaryRect)
  }

  private func check() {
    guard !tokens.isEmpty, let window = window() else { return }
    let bounds = window.bounds
    if let geometry = CaptureGeometry(width: Double(bounds.width), height: Double(bounds.height), screenScale: 1) {
      report(geometry)
    }
  }
}
#endif

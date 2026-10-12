#if canImport(UIKit)
import UIKit

/// Feeds the key window's size to `SurfaceReporter` between captures:
/// key-value observation of the key window's `frame` and `bounds` (scene
/// resizes in split view and Stage Manager, rotation), plus a check when a
/// window becomes key, when the app becomes active, and on device rotation
/// (again after the rotation animation). Every capture also reports the
/// size it draws with (`FrameMasks`), so a change these miss is still
/// reported before that capture's result. Main thread only.
final class SurfaceObserver {
  /// Longer than UIKit's rotation animation (about 0.4 s).
  static let settleDelay: TimeInterval = 0.6

  private let reporter: SurfaceReporter
  private let center: NotificationCenter
  private let window: () -> UIWindow?
  private var tokens: [NSObjectProtocol] = []
  private var sizeObservations: [NSKeyValueObservation] = []
  private weak var observedWindow: UIWindow?

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
    sizeObservations.forEach { $0.invalidate() }
    sizeObservations.removeAll()
    observedWindow = nil
    UIDevice.current.endGeneratingDeviceOrientationNotifications()
  }

  /// Reports the key window's size, and follows its size from now on.
  private func check() {
    guard !tokens.isEmpty, let window = window() else { return }
    if window !== observedWindow {
      observe(window)
    }
    report(window)
  }

  private func observe(_ window: UIWindow) {
    sizeObservations.forEach { $0.invalidate() }
    observedWindow = window
    let onChange: (UIWindow) -> Void = { [weak self] changed in
      // KVO may arrive off the main thread when a setter is called there.
      DispatchQueue.main.async { self?.report(changed) }
    }
    sizeObservations = [
      window.observe(\.frame) { changed, _ in onChange(changed) },
      window.observe(\.bounds) { changed, _ in onChange(changed) },
    ]
  }

  private func report(_ window: UIWindow) {
    guard !tokens.isEmpty, window === observedWindow,
      let geometry = CaptureGeometry(width: Double(window.bounds.width), height: Double(window.bounds.height))
    else { return }
    reporter.observe(geometry.boundaryRect)
  }
}
#endif

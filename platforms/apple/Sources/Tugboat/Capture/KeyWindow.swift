#if canImport(UIKit)
import UIKit

/// The window captures draw and the surface follows: the key window of a
/// foreground-active scene, else of any connected scene. Main thread only.
enum KeyWindow {
  static func current(in application: UIApplication = .shared) -> UIWindow? {
    let scenes = application.connectedScenes.compactMap { $0 as? UIWindowScene }
    let active = scenes.filter { $0.activationState == .foregroundActive }
    for scene in active + scenes.filter({ $0.activationState != .foregroundActive }) {
      if let window = scene.windows.first(where: { $0.isKeyWindow }) {
        return window
      }
    }
    return nil
  }

  /// The key window's size in points, else the screen's.
  static func viewport(fallback: DeviceSnapshot) -> (width: Double, height: Double) {
    guard let bounds = current()?.bounds, bounds.width > 0, bounds.height > 0 else {
      return (fallback.screenWidth, fallback.screenHeight)
    }
    return (Double(bounds.width), Double(bounds.height))
  }
}
#endif

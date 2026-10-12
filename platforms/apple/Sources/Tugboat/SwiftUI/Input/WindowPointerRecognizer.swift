#if canImport(UIKit)
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Observes every touch delivered to one window (native SDK note section 5)
/// without changing how the app handles it:
///
/// - it never recognizes, so it never cancels or delays a touch for any
///   view (`cancelsTouchesInView`, `delaysTouchesBegan`,
///   `delaysTouchesEnded` are all off);
/// - it can neither prevent nor be prevented by another recognizer, and
///   recognizes simultaneously with all of them;
/// - it fails once its last touch ends, so UIKit resets it for the next
///   sequence. No swizzling.
///
/// Samples go to `onSample` in delivery order; `onReset` runs when UIKit
/// resets it (any touch still open is then lost). Main thread only.
final class WindowPointerRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
  private let onSample: (TouchSample) -> Void
  private let onReset: () -> Void
  private var open = Set<ObjectIdentifier>()

  init(onSample: @escaping (TouchSample) -> Void, onReset: @escaping () -> Void) {
    self.onSample = onSample
    self.onReset = onReset
    super.init(target: nil, action: nil)
    cancelsTouchesInView = false
    delaysTouchesBegan = false
    delaysTouchesEnded = false
    requiresExclusiveTouchType = false
    delegate = self
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    for touch in touches {
      open.insert(ObjectIdentifier(touch))
      deliver(touch, .began)
    }
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    for touch in touches {
      deliver(touch, .moved)
    }
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    finish(touches, .ended)
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    finish(touches, .cancelled)
  }

  override func reset() {
    super.reset()
    open.removeAll()
    onReset()
  }

  override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
    false
  }

  override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
    false
  }

  override func shouldRequireFailure(of otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    false
  }

  override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    false
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    true
  }

  private func finish(_ touches: Set<UITouch>, _ phase: TouchPhase) {
    for touch in touches {
      open.remove(ObjectIdentifier(touch))
      deliver(touch, phase)
    }
    if open.isEmpty, state == .possible {
      state = .failed
    }
  }

  private func deliver(_ touch: UITouch, _ phase: TouchPhase) {
    let sample = TouchSample(
      key: ObjectIdentifier(touch),
      phase: phase,
      location: touch.location(in: view),
      uptime: touch.timestamp,
      device: WindowPointerRecognizer.device(of: touch)
    )
    onSample(sample)
  }

  static func device(of touch: UITouch) -> PointerDevice {
    switch touch.type {
    case .pencil: return .stylus
    case .indirectPointer: return .mouse
    case .direct, .indirect: return .touch
    @unknown default: return .touch
    }
  }
}
#endif

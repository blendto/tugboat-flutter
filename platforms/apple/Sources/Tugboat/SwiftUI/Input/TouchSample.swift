import Foundation

/// The phase of one touch in one delivery to the window recognizer.
enum TouchPhase {
  case began
  case moved
  case ended
  case cancelled
}

/// The engine's `input.pointer.device` values the adapter produces.
enum PointerDevice: String {
  case touch
  case mouse
  case stylus
}

/// One touch as the window recognizer saw it: which touch (`key`, the
/// `UITouch` identity), its phase, its location in window points, and its
/// `UITouch.timestamp` (seconds of `systemUptime`).
struct TouchSample {
  let key: ObjectIdentifier
  let phase: TouchPhase
  let location: CGPoint
  let uptime: TimeInterval
  let device: PointerDevice
}

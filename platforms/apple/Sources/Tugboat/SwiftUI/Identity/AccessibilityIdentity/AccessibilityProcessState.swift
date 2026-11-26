import Foundation

/// What ADR 0010 decides once per process launch and keeps across sessions
/// (`stop` and `start` build a new adapter, not a new process): the
/// `.sampled` draw, and whether the accessibility tree was activated. The
/// tree's cost cannot be undone, so neither is ever drawn or done twice.
///
/// Main thread only.
final class AccessibilityProcessState {
  static let shared = AccessibilityProcessState()

  enum Activation: Equatable {
    case none
    /// `accessibilityActivate()` waits for the main queue's next turn.
    case scheduled
    case done
  }

  var activation = Activation.none
  private var sampledIn: Bool?

  /// Whether this process is sampled in. The first call draws (`draw` gives
  /// a value in 0..<1) against `rate` clamped to 0...1 (NaN is 0); later
  /// calls return that answer whatever their rate.
  func isSampledIn(rate: Double, draw: () -> Double) -> Bool {
    if let drawn = sampledIn {
      return drawn
    }
    let clamped = rate.isNaN ? 0 : min(max(rate, 0), 1)
    let drawn = draw() < clamped
    sampledIn = drawn
    return drawn
  }
}

import Foundation

/// Whether the SwiftUI adapter may read the in-process accessibility tree to
/// identify untagged SwiftUI taps (ADR 0010). See
/// `TugboatConfig.swiftUIAccessibilityIdentity` for what it costs; prefer
/// `.tugboatTag`.
public enum SwiftUIAccessibilityIdentity: Equatable {
  /// The default. The tree is never built or read, even when VoiceOver is
  /// running.
  case off
  /// On in a random share of process launches: `rate` is clamped to 0...1
  /// (NaN is 0) and drawn once per process launch, not per session or tap.
  /// A process that is not sampled in never reads the tree, including in
  /// later sessions.
  case sampled(rate: Double)
  /// On in every process.
  case on
}
